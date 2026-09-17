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
SELECT
    dp.nom,
    COUNT(m.id) AS nb_livraisons
FROM distribution_points dp
JOIN missions m ON m.distribution_point_id = dp.id
WHERE m.statut = 'livre'
GROUP BY dp.id, dp.nom
ORDER BY nb_livraisons DESC
LIMIT 10;

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
