-- ============================================================
-- Safe Speedelivery — Schéma de base de données (PostgreSQL)
-- Rôles : directeur, pm, chef_park, chauffeur
-- ============================================================

-- Extension utile pour générer des UUID si besoin plus tard
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------- Types énumérés ----------
CREATE TYPE user_role AS ENUM ('directeur', 'pm', 'chef_park', 'chauffeur');
CREATE TYPE vehicle_status AS ENUM ('actif', 'en_entretien', 'hors_service');
CREATE TYPE mission_status AS ENUM ('emis', 'chargement', 'en_route', 'livre', 'annule');
CREATE TYPE maintenance_status AS ENUM ('ok', 'a_planifier', 'urgent', 'realise');
CREATE TYPE defect_status AS ENUM ('urgent', 'a_verifier', 'resolu');
CREATE TYPE report_status AS ENUM ('en_attente', 'valide');

-- ---------- Utilisateurs (les 4 rôles) ----------
CREATE TABLE users (
    id              SERIAL PRIMARY KEY,
    nom             VARCHAR(100)  NOT NULL,
    prenom          VARCHAR(100)  NOT NULL,
    email           VARCHAR(150)  NOT NULL UNIQUE,
    password_hash   VARCHAR(255)  NOT NULL,
    role            user_role     NOT NULL,
    pm_id           INTEGER       REFERENCES users(id) ON DELETE SET NULL, -- rattachement d'un chauffeur à son PM
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- Un chauffeur doit être rattaché à un PM ; les autres rôles n'ont pas de pm_id
ALTER TABLE users ADD CONSTRAINT chk_chauffeur_pm
    CHECK (
        (role = 'chauffeur' AND pm_id IS NOT NULL)
        OR (role <> 'chauffeur')
    );

CREATE INDEX idx_users_pm_id ON users(pm_id);
CREATE INDEX idx_users_role  ON users(role);

-- ---------- Véhicules (gérés par le Chef Park) ----------
CREATE TABLE vehicles (
    id              SERIAL PRIMARY KEY,
    immatriculation VARCHAR(20)     NOT NULL UNIQUE,
    modele          VARCHAR(100),
    statut          vehicle_status  NOT NULL DEFAULT 'actif',
    km_total        NUMERIC(10,1)   NOT NULL DEFAULT 0,
    chef_park_id    INTEGER         REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now()
);

CREATE INDEX idx_vehicles_chef_park ON vehicles(chef_park_id);

-- ---------- Points de distribution ----------
CREATE TABLE distribution_points (
    id      SERIAL PRIMARY KEY,
    nom     VARCHAR(150) NOT NULL UNIQUE
);

-- ---------- Missions / ordres de mission ----------
-- NOTE (mise à jour) : un ordre de mission (OM) peut couvrir PLUSIEURS arrêts/destinations
-- dans la même tournée (constaté sur les données réelles fournies par le client, fichier
-- IVECO193.xlsx : ex. un seul OM avec 2 destinations séparées par une virgule).
-- Le trajet global (départ -> dernier arrêt) reste sur la mission ; le détail des arrêts
-- intermédiaires est porté par la table mission_stops ci-dessous.
CREATE TABLE missions (
    id                      SERIAL PRIMARY KEY,
    chauffeur_id            INTEGER NOT NULL REFERENCES users(id),
    vehicle_id              INTEGER NOT NULL REFERENCES vehicles(id),
    pm_id                   INTEGER NOT NULL REFERENCES users(id), -- PM qui a créé la mission
    trajet_depart           VARCHAR(150) NOT NULL,
    trajet_arrivee          VARCHAR(150) NOT NULL,
    marchandise             VARCHAR(255),
    statut                  mission_status NOT NULL DEFAULT 'emis',
    date_creation           TIMESTAMPTZ NOT NULL DEFAULT now(),
    date_livraison          TIMESTAMPTZ
);

CREATE INDEX idx_missions_chauffeur ON missions(chauffeur_id);
CREATE INDEX idx_missions_pm        ON missions(pm_id);
CREATE INDEX idx_missions_statut    ON missions(statut);
CREATE INDEX idx_missions_date      ON missions(date_creation);

-- ---------- Arrêts d'une mission (support des tournées multi-destinations) ----------
CREATE TABLE mission_stops (
    id                      SERIAL PRIMARY KEY,
    mission_id              INTEGER NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    distribution_point_id   INTEGER NOT NULL REFERENCES distribution_points(id),
    ordre_passage           INTEGER NOT NULL DEFAULT 1,
    UNIQUE (mission_id, ordre_passage)
);

CREATE INDEX idx_mission_stops_mission ON mission_stops(mission_id);
CREATE INDEX idx_mission_stops_point   ON mission_stops(distribution_point_id);

-- ---------- Historique de statut (traçabilité, type journal d'audit) ----------
CREATE TABLE mission_status_history (
    id          SERIAL PRIMARY KEY,
    mission_id  INTEGER NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    ancien_statut mission_status,
    nouveau_statut mission_status NOT NULL,
    changed_by  INTEGER REFERENCES users(id),
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Maintenance / entretien ----------
CREATE TABLE maintenance (
    id          SERIAL PRIMARY KEY,
    vehicle_id  INTEGER NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
    type        VARCHAR(100) NOT NULL,
    date_prevue DATE,
    km_seuil    NUMERIC(10,1),
    statut      maintenance_status NOT NULL DEFAULT 'ok',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_maintenance_vehicle ON maintenance(vehicle_id);

-- ---------- Carburant ----------
-- NOTE (mise à jour) : "solde" = solde de la carte carburant après ce plein, constaté dans
-- le suivi manuel actuel du client (fichier IVECO193.xlsx). À confirmer avec le client si
-- ce solde correspond bien à une carte carburant (montant en DT) ou à autre chose.
CREATE TABLE fuel_logs (
    id          SERIAL PRIMARY KEY,
    vehicle_id  INTEGER NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
    mission_id  INTEGER REFERENCES missions(id) ON DELETE SET NULL,
    date        DATE NOT NULL DEFAULT CURRENT_DATE,
    litres      NUMERIC(8,2) NOT NULL,
    cout        NUMERIC(10,2),
    solde       NUMERIC(10,2) -- solde restant sur la carte carburant après ce plein (à valider)
);

CREATE INDEX idx_fuel_vehicle ON fuel_logs(vehicle_id);

-- ---------- Défauts techniques ----------
CREATE TABLE defects (
    id                  SERIAL PRIMARY KEY,
    vehicle_id          INTEGER NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
    chauffeur_id        INTEGER REFERENCES users(id),
    description         TEXT NOT NULL,
    statut              defect_status NOT NULL DEFAULT 'a_verifier',
    date_signalement    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_defects_vehicle ON defects(vehicle_id);

-- ---------- Évaluations des chauffeurs ----------
CREATE TABLE evaluations (
    id              SERIAL PRIMARY KEY,
    chauffeur_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pm_id           INTEGER NOT NULL REFERENCES users(id),
    score           NUMERIC(3,1) NOT NULL CHECK (score >= 0 AND score <= 5),
    commentaire     TEXT,
    date            DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE INDEX idx_evaluations_chauffeur ON evaluations(chauffeur_id);

-- ---------- PV mensuel / facturation ----------
CREATE TABLE monthly_reports (
    id                  SERIAL PRIMARY KEY,
    pm_id               INTEGER NOT NULL REFERENCES users(id),
    mois                DATE NOT NULL,             -- toujours le 1er jour du mois, ex. 2026-09-01
    nb_missions         INTEGER NOT NULL DEFAULT 0,
    statut_validation   report_status NOT NULL DEFAULT 'en_attente',
    date_validation     TIMESTAMPTZ,
    UNIQUE (pm_id, mois)
);

-- ---------- Journal d'audit général (bonnes pratiques Tunisys) ----------
CREATE TABLE audit_log (
    id              SERIAL PRIMARY KEY,
    user_id         INTEGER REFERENCES users(id),
    action          VARCHAR(50) NOT NULL,     -- ex. 'CREATE_MISSION', 'VALIDATE_PV'
    table_cible     VARCHAR(50) NOT NULL,
    enregistrement_id INTEGER,
    details         JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_user ON audit_log(user_id);
CREATE INDEX idx_audit_table ON audit_log(table_cible);

-- ============================================================
-- EN ATTENTE DE VALIDATION CLIENT — Prime journalière chauffeur
-- Barème identifié dans le suivi Excel actuel du client (IVECO193.xlsx) :
-- 0-2 missions/jour = 0 DT, 3 = 15 DT, 4 = 35 DT, 5 = 60 DT, 6 = 90 DT.
-- Ne pas activer cette fonctionnalité côté application tant que le client n'a pas confirmé
-- qu'il souhaite la digitaliser (cf. message envoyé listant les "ajouts").
-- ============================================================
CREATE TABLE bonus_rules (
    id              SERIAL PRIMARY KEY,
    nb_missions_min INTEGER NOT NULL,
    nb_missions_max INTEGER,          -- NULL = pas de plafond
    montant         NUMERIC(8,2) NOT NULL
);

CREATE TABLE driver_daily_bonus (
    id              SERIAL PRIMARY KEY,
    chauffeur_id    INTEGER NOT NULL REFERENCES users(id),
    date            DATE NOT NULL,
    nb_missions     INTEGER NOT NULL,
    montant         NUMERIC(8,2) NOT NULL,
    UNIQUE (chauffeur_id, date)
);

-- Barème de départ observé (à confirmer avant toute utilisation)
INSERT INTO bonus_rules (nb_missions_min, nb_missions_max, montant) VALUES
    (0, 2, 0),
    (3, 3, 15),
    (4, 4, 35),
    (5, 5, 60),
    (6, NULL, 90);

-- ============================================================
-- Données de départ (rôles de base, à adapter avec les vrais comptes)
-- ============================================================
INSERT INTO users (nom, prenom, email, password_hash, role) VALUES
    ('Ben Ali', 'Karim', 'directeur@ssd.tn', 'CHANGE_ME_HASH', 'directeur'),
    ('Trabelsi', 'Sami', 'chefpark@ssd.tn', 'CHANGE_ME_HASH', 'chef_park');

-- Exemple de PM (rattaché à personne, il rattache lui-même ses chauffeurs)
INSERT INTO users (nom, prenom, email, password_hash, role) VALUES
    ('Yaich', 'Nizar', 'pm1@ssd.tn', 'CHANGE_ME_HASH', 'pm');
