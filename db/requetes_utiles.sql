-- ============================================================
-- Safe Speedelivery — Requêtes utiles (exemples prêts à adapter)
-- ============================================================

-- 1) DASHBOARD DIRECTEUR : indicateurs globaux
SELECT
    (SELECT COUNT(*) FROM vehicles WHERE statut = 'actif')                 AS camions_actifs,
    (SELECT COUNT(*) FROM missions WHERE date_creation::date = CURRENT_DATE) AS missions_du_jour,
    (SELECT COUNT(*) FROM defects WHERE statut = 'urgent')
      + (SELECT COUNT(*) FROM maintenance WHERE statut = 'urgent')          AS alertes_en_cours;

-- 2) DASHBOARD PM : mêmes indicateurs, mais limités à sa propre équipe
-- (:pm_id est l'id du PM connecté)
SELECT
    COUNT(*) FILTER (WHERE m.statut IN ('emis','chargement','en_route')) AS missions_en_cours,
    COUNT(*) FILTER (WHERE m.date_creation::date = CURRENT_DATE)          AS missions_du_jour
FROM missions m
WHERE m.pm_id = :pm_id;

-- 3) Missions en cours avec chauffeur et véhicule (vue type écran 1)
SELECT
    m.id,
    m.trajet_depart,
    m.trajet_arrivee,
    u.nom || ' ' || u.prenom AS chauffeur,
    v.immatriculation,
    m.statut
FROM missions m
JOIN users u    ON u.id = m.chauffeur_id
JOIN vehicles v ON v.id = m.vehicle_id
WHERE m.statut <> 'livre'
ORDER BY m.date_creation DESC;

-- 4) Planning d'un chauffeur, classé par jour (:chauffeur_id)
SELECT
    m.date_creation::date AS jour,
    m.trajet_depart,
    m.trajet_arrivee,
    m.statut
FROM missions m
WHERE m.chauffeur_id = :chauffeur_id
  AND m.date_creation::date >= CURRENT_DATE
ORDER BY m.date_creation;

-- 5) Véhicules à alerter pour entretien (seuil dépassé ou proche)
SELECT
    v.immatriculation,
    v.km_total,
    ma.km_seuil,
    ma.km_seuil - v.km_total AS km_restants,
    CASE
        WHEN v.km_total >= ma.km_seuil THEN 'urgent'
        WHEN ma.km_seuil - v.km_total <= 2000 THEN 'a_planifier'
        ELSE 'ok'
    END AS niveau_alerte
FROM vehicles v
JOIN maintenance ma ON ma.vehicle_id = v.id
WHERE ma.statut <> 'realise'
ORDER BY km_restants ASC;

-- 6) Consommation moyenne de carburant par véhicule (L/100km)
SELECT
    v.immatriculation,
    ROUND(SUM(f.litres) / NULLIF(v.km_total, 0) * 100, 2) AS conso_moyenne_l_100km
FROM vehicles v
JOIN fuel_logs f ON f.vehicle_id = v.id
GROUP BY v.id, v.immatriculation
ORDER BY conso_moyenne_l_100km DESC;

-- 7) Défauts en attente de traitement (pour le Chef Park)
SELECT
    d.id,
    v.immatriculation,
    u.nom || ' ' || u.prenom AS signale_par,
    d.description,
    d.statut,
    d.date_signalement
FROM defects d
JOIN vehicles v ON v.id = d.vehicle_id
LEFT JOIN users u ON u.id = d.chauffeur_id
WHERE d.statut IN ('urgent', 'a_verifier')
ORDER BY d.date_signalement DESC;

-- 8) Classement des points de distribution les plus visités
-- (mis à jour : passe par mission_stops pour compter chaque arrêt d'une tournée multi-destinations)
SELECT
    dp.nom,
    COUNT(ms.id) AS nb_livraisons
FROM distribution_points dp
JOIN mission_stops ms ON ms.distribution_point_id = dp.id
JOIN missions m        ON m.id = ms.mission_id
WHERE m.statut = 'livre'
GROUP BY dp.id, dp.nom
ORDER BY nb_livraisons DESC
LIMIT 10;

-- 8bis) Détail des arrêts d'une mission donnée, dans l'ordre de passage (:mission_id)
SELECT
    ms.ordre_passage,
    dp.nom AS point_de_distribution
FROM mission_stops ms
JOIN distribution_points dp ON dp.id = ms.distribution_point_id
WHERE ms.mission_id = :mission_id
ORDER BY ms.ordre_passage;

-- 9) Évaluation moyenne par chauffeur
SELECT
    u.nom || ' ' || u.prenom AS chauffeur,
    ROUND(AVG(e.score), 1) AS note_moyenne,
    COUNT(e.id) AS nb_evaluations
FROM users u
JOIN evaluations e ON e.chauffeur_id = u.id
WHERE u.role = 'chauffeur'
GROUP BY u.id
ORDER BY note_moyenne DESC;

-- 10) Génération du PV mensuel pour un PM (:pm_id, :mois ex. '2026-09-01')
SELECT
    COUNT(*) AS nb_missions_du_mois
FROM missions m
WHERE m.pm_id = :pm_id
  AND m.statut = 'livre'
  AND date_trunc('month', m.date_livraison) = :mois::date;

-- Puis on enregistre / met à jour le PV correspondant :
INSERT INTO monthly_reports (pm_id, mois, nb_missions, statut_validation)
VALUES (:pm_id, :mois, :nb_missions_du_mois, 'en_attente')
ON CONFLICT (pm_id, mois)
DO UPDATE SET nb_missions = EXCLUDED.nb_missions;

-- 11) Vérifier qu'un PV peut être validé
-- (aucune mission de ce PM sur ce mois ne doit rester "en cours")
SELECT COUNT(*) = 0 AS peut_etre_valide
FROM missions m
WHERE m.pm_id = :pm_id
  AND date_trunc('month', m.date_creation) = :mois::date
  AND m.statut NOT IN ('livre', 'annule');

-- 12) Solde de carte carburant restant après le dernier plein d'un véhicule (:vehicle_id)
SELECT vehicle_id, date, solde
FROM fuel_logs
WHERE vehicle_id = :vehicle_id
ORDER BY date DESC
LIMIT 1;

-- ============================================================
-- EN ATTENTE DE VALIDATION CLIENT — Prime journalière chauffeur
-- Ne pas exposer ces requêtes dans l'application tant que la fonctionnalité
-- n'est pas confirmée par le client.
-- ============================================================

-- 13) Calculer la prime du jour pour un chauffeur selon le barème (:chauffeur_id, :date, :nb_missions)
SELECT montant
FROM bonus_rules
WHERE :nb_missions >= nb_missions_min
  AND (nb_missions_max IS NULL OR :nb_missions <= nb_missions_max)
LIMIT 1;

-- 14) Enregistrer la prime calculée pour un chauffeur et une date donnés
INSERT INTO driver_daily_bonus (chauffeur_id, date, nb_missions, montant)
VALUES (:chauffeur_id, :date, :nb_missions, :montant)
ON CONFLICT (chauffeur_id, date)
DO UPDATE SET nb_missions = EXCLUDED.nb_missions, montant = EXCLUDED.montant;
