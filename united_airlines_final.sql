-- 1.EXPLORATORY DATA ANALYSIS (EDA)
-- What is the average delay and what percentage of flights depart later than scheduled?
SELECT
    AVG(CASE WHEN TIMESTAMPDIFF(MINUTE, scheduled_departure_datetime_local, actual_departure_datetime_local) > 0 
             THEN TIMESTAMPDIFF(MINUTE, scheduled_departure_datetime_local, actual_departure_datetime_local) 
             ELSE NULL END) AS average_delay_for_delayed_flights,
    (COUNT(CASE WHEN actual_departure_datetime_local > scheduled_departure_datetime_local THEN 1 END) / COUNT(*)) * 100 AS percentage_of_delayed_flights
FROM 
    flight_level_data;

-- How many flights have scheduled ground time close to or below the minimum turn mins?
SELECT
    COUNT(*) AS flights_with_tight_turnaround
FROM
    flight_level_data
WHERE
    scheduled_ground_time_minutes <= minimum_turn_minutes;
    
-- What is the average ratio of transfer bags vs. checked bags across flights?
with t1 as (
select (select count(*) from bag_level_data where bag_type = "Transfer") as a,
(select count(*) from bag_level_data where bag_type = "Hot Transfer") as b,
(select count(*) from bag_level_data where bag_type = "origin") as c )
select (a + b)/ c Transfer_to_checked_ratio from t1;

-- How do passenger loads compare across flights, and do higher loads correlate with operational difficulty?
SELECT
    AVG(pnr.total_pax / NULLIF(flt.total_seats, 0)) * 100 AS average_load_factor_percentage,
    MIN(pnr.total_pax / NULLIF(flt.total_seats, 0)) * 100 AS min_load_factor_percentage,
    MAX(pnr.total_pax / NULLIF(flt.total_seats, 0)) * 100 AS max_load_factor_percentage
FROM
    flight_level_data flt
JOIN
    pnr_flight_level_data pnr ON flt.flight_number = pnr.flight_number AND flt.scheduled_departure_date_local = pnr.scheduled_departure_date_local;

-- Are high special service requests flights also high-delay after controlling for load?
WITH SsrCounts AS (
    SELECT record_locator, COUNT(*) AS ssr_count
    FROM pnr_remark_level_data
    GROUP BY record_locator
)
SELECT
    flt.flight_number,
    flt.scheduled_departure_date_local,
    (pnr.total_pax / NULLIF(flt.total_seats, 0)) AS load_factor,
    COALESCE(ssr.ssr_count, 0) AS special_service_requests,
    TIMESTAMPDIFF(MINUTE, flt.scheduled_departure_datetime_local, flt.actual_departure_datetime_local) AS departure_delay_minutes
FROM
    flight_level_data flt
JOIN
    pnr_flight_level_data pnr ON flt.flight_number = pnr.flight_number AND flt.scheduled_departure_date_local = pnr.scheduled_departure_date_local
LEFT JOIN
    SsrCounts ssr ON pnr.record_locator = ssr.record_locator;
    
-- Flight Difficulty Score Development
USE united_airlines_db; 
WITH T1 AS (WITH
PassengerAggregates AS (
    SELECT
        flight_number,
        scheduled_departure_date_local,
        SUM(total_pax) AS actual_total_pax,
        SUM(lap_child_count) AS total_lap_children
    FROM
        pnr_flight_level_data
    GROUP BY
        flight_number, scheduled_departure_date_local
),
BaggageAggregates AS (
    SELECT
        flight_number,
        scheduled_departure_date_local,
        SUM(CASE WHEN bag_type = 'Transfer' THEN 1 ELSE 0 END) AS transfer_bag_count
    FROM
        bag_level_data
    GROUP BY
        flight_number, scheduled_departure_date_local
),
SsrAggregates AS (
    SELECT
        pnr_f.flight_number,
        pnr_f.scheduled_departure_date_local,
        COUNT(pnr_r.special_service_request) AS ssr_count
    FROM
        pnr_flight_level_data pnr_f
    JOIN
        pnr_remark_level_data pnr_r ON pnr_f.record_locator = pnr_r.record_locator
    WHERE
        pnr_r.special_service_request IS NOT NULL AND pnr_r.special_service_request != ''
    GROUP BY
        pnr_f.flight_number, pnr_f.scheduled_departure_date_local
),
FlightBaseFeatures AS (
    SELECT
        flt.flight_number,
        flt.scheduled_departure_date_local,
        flt.scheduled_departure_station_code,
        flt.scheduled_arrival_station_code,
        flt.minimum_turn_minutes / NULLIF(flt.scheduled_ground_time_minutes, 0) AS time_pressure_ratio,
        pnr.actual_total_pax / NULLIF(flt.total_seats, 0) AS load_factor,
        COALESCE(ssr.ssr_count, 0) AS ssr_count,
        COALESCE(bags.transfer_bag_count, 0) AS transfer_bag_count,
        CASE WHEN flt.scheduled_departure_station_code IN ('ORD', 'EWR', 'SFO', 'LAX', 'DEN', 'IAH') THEN 1 ELSE 0 END AS is_hub_departure,
        CASE WHEN HOUR(flt.scheduled_departure_datetime_local) BETWEEN 16 AND 19 THEN 1 ELSE 0 END AS is_peak_hour
    FROM
        flight_level_data flt
    LEFT JOIN
        PassengerAggregates pnr ON flt.flight_number = pnr.flight_number AND flt.scheduled_departure_date_local = pnr.scheduled_departure_date_local
    LEFT JOIN
        BaggageAggregates bags ON flt.flight_number = bags.flight_number AND flt.scheduled_departure_date_local = bags.scheduled_departure_date_local
    LEFT JOIN
        SsrAggregates ssr ON flt.flight_number = ssr.flight_number AND flt.scheduled_departure_date_local = ssr.scheduled_departure_date_local
    WHERE
        pnr.actual_total_pax IS NOT NULL AND flt.scheduled_ground_time_minutes > 0
),
MinMaxValues AS (
    SELECT
        MIN(time_pressure_ratio) AS min_pressure, MAX(time_pressure_ratio) AS max_pressure,
        MIN(load_factor) AS min_load, MAX(load_factor) AS max_load,
        MIN(ssr_count) AS min_ssr, MAX(ssr_count) AS max_ssr,
        MIN(transfer_bag_count) AS min_bags, MAX(transfer_bag_count) AS max_bags
    FROM FlightBaseFeatures
),
NormalizedFeatures AS (
    SELECT
        f.*,
        (f.time_pressure_ratio - mm.min_pressure) / NULLIF(mm.max_pressure - mm.min_pressure, 0) AS norm_pressure,
        (f.load_factor - mm.min_load) / NULLIF(mm.max_load - mm.min_load, 0) AS norm_load,
        (f.ssr_count - mm.min_ssr) / NULLIF(mm.max_ssr - mm.min_ssr, 0) AS norm_ssr,
        (f.transfer_bag_count - mm.min_bags) / NULLIF(mm.max_bags - mm.min_bags, 0) AS norm_bags
    FROM FlightBaseFeatures f, MinMaxValues mm
),
ScoredFlights AS (
    SELECT
        nf.flight_number,
        nf.scheduled_departure_date_local,
        nf.scheduled_departure_station_code,
        nf.scheduled_arrival_station_code,
        round(nf.norm_pressure,3) as time_pressure_factor,
        round(nf.norm_load,3) as load_factor,
        round(nf.norm_ssr,3) as ssr_factor,
        round(nf.norm_bags,3) as luggage_factor,
        round((
            (nf.norm_pressure * 0.40) + (nf.norm_load * 0.15) + (nf.norm_ssr * 0.15) +
            (nf.norm_bags * 0.10) + (nf.is_hub_departure * 0.10) + (nf.is_peak_hour * 0.10)
        ),3) AS difficulty_score
    FROM NormalizedFeatures nf
)
SELECT
    *,
    CASE 
        WHEN NTILE(3) OVER (ORDER BY difficulty_score DESC) = 1 THEN 'Difficult'
        WHEN NTILE(3) OVER (ORDER BY difficulty_score DESC) = 2 THEN 'Medium'
        ELSE 'Easy'
    END AS difficulty_category
FROM
    ScoredFlights
ORDER BY
    difficulty_score DESC)
    SELECT T1.*, f.scheduled_departure_datetime_local FROM T1 JOIN flight_level_data f ON T1.flight_number = f.flight_number
    AND T1.scheduled_departure_date_local = f.scheduled_departure_date_local AND T1.scheduled_departure_station_code = f.scheduled_departure_station_code;
    
--  Post-Analysis & Operational Insights
-- Summarizing which destinations consistently show more difficulty
SELECT
    scheduled_arrival_station_code AS destination,
    AVG(difficulty_score) AS average_difficulty_score,
    AVG(CASE WHEN difficulty_category = 'Difficult' THEN 1.0 ELSE 0.0 END) * 100 AS percentage_difficult_flights,
    SUM(CASE WHEN difficulty_category = 'Difficult' THEN 1 ELSE 0 END) AS count_of_difficult_flights,
	COUNT(*) AS total_flights
FROM
    temp_flight_scores
GROUP BY
    scheduled_arrival_station_code
HAVING
    COUNT(*) > 20
ORDER BY
    percentage_difficult_flights DESC;
    





    