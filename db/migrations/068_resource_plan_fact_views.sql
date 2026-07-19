-- 068_resource_plan_fact_views — VIEW для агрегации план/факт ресурсов по работе (не материализация,
-- см. backend-spec.md §5 "Ресурсная агрегация — VIEW, не материализация"). Три VIEW (по одному на вид
-- ресурса), группировка по task_id + resource_id (конкретный ресурс, раскрывая группы через
-- *_group_resource) — план и факт сведены по совпадающему ресурсу и единице измерения.
--
-- РЕШЕНИЕ: групповые плановые назначения (group_id NOT NULL) раскрываются в разрезе КАЖДОГО члена
-- группы (JOIN group_resource), чтобы план и факт сопоставлялись на уровне одного ресурса — это
-- единственный способ дать осмысленное "план X / факт Y" по конкретному ресурсу, когда в плане
-- была группа, а факт всегда указывает на конкретного члена группы (resources-business.md п.9).
-- Названия колонок унифицированы (task_id, section_id, resource_id, resource_name, unit_id,
-- unit_short_name, plan_qty, fact_qty) для единообразного использования на фронтенде.

CREATE OR REPLACE VIEW personnel_resource_plan_fact AS
WITH plan_expanded AS (
  -- Плановые строки с конкретным ресурсом.
  SELECT prp.task_daily_plan_id, pr.id AS resource_id, prp.plan_qty
  FROM personnel_resource_plan prp
  JOIN personnel_resource pr ON pr.id = prp.resource_id
  WHERE prp.status <> 'deprecated'
  UNION ALL
  -- Плановые строки с группой: раскрываем по членам группы (план делится не физически — каждый
  -- член группы получает информационную строку с тем же plan_qty группы, т.к. диспетчер выберет
  -- только одного при факте; сравнение план/факт корректно только для фактически выбранного).
  SELECT prp.task_daily_plan_id, pgr.resource_id, prp.plan_qty
  FROM personnel_resource_plan prp
  JOIN personnel_group_resource pgr ON pgr.group_id = prp.group_id AND pgr.status <> 'deprecated'
  WHERE prp.status <> 'deprecated' AND prp.group_id IS NOT NULL
),
fact_expanded AS (
  SELECT prf.task_daily_plan_id, prf.resource_id, sum(prf.fact_qty) AS fact_qty
  FROM personnel_resource_fact prf
  GROUP BY prf.task_daily_plan_id, prf.resource_id
)
SELECT
  tdp.task_id,
  tdp.task_section_id,
  pr.id AS resource_id,
  pr.name AS resource_name,
  pr.unit_id,
  pu.short_name AS unit_short_name,
  COALESCE(sum(pe.plan_qty), 0) AS plan_qty,
  COALESCE(max(fe.fact_qty), 0) AS fact_qty
FROM personnel_resource pr
JOIN personnel_unit pu ON pu.id = pr.unit_id
LEFT JOIN plan_expanded pe ON pe.resource_id = pr.id
LEFT JOIN task_daily_plan tdp ON tdp.id = pe.task_daily_plan_id
LEFT JOIN fact_expanded fe ON fe.resource_id = pr.id AND fe.task_daily_plan_id = pe.task_daily_plan_id
WHERE tdp.task_id IS NOT NULL
GROUP BY tdp.task_id, tdp.task_section_id, pr.id, pr.name, pr.unit_id, pu.short_name;

CREATE OR REPLACE VIEW equipment_resource_plan_fact AS
WITH plan_expanded AS (
  SELECT erp.task_daily_plan_id, er.id AS resource_id, erp.plan_qty
  FROM equipment_resource_plan erp
  JOIN equipment_resource er ON er.id = erp.resource_id
  WHERE erp.status <> 'deprecated'
  UNION ALL
  SELECT erp.task_daily_plan_id, egr.resource_id, erp.plan_qty
  FROM equipment_resource_plan erp
  JOIN equipment_group_resource egr ON egr.group_id = erp.group_id AND egr.status <> 'deprecated'
  WHERE erp.status <> 'deprecated' AND erp.group_id IS NOT NULL
),
fact_expanded AS (
  SELECT erf.task_daily_plan_id, erf.resource_id, sum(erf.fact_qty) AS fact_qty
  FROM equipment_resource_fact erf
  GROUP BY erf.task_daily_plan_id, erf.resource_id
)
SELECT
  tdp.task_id,
  tdp.task_section_id,
  er.id AS resource_id,
  er.name AS resource_name,
  er.unit_id,
  eu.short_name AS unit_short_name,
  COALESCE(sum(pe.plan_qty), 0) AS plan_qty,
  COALESCE(max(fe.fact_qty), 0) AS fact_qty
FROM equipment_resource er
JOIN equipment_unit eu ON eu.id = er.unit_id
LEFT JOIN plan_expanded pe ON pe.resource_id = er.id
LEFT JOIN task_daily_plan tdp ON tdp.id = pe.task_daily_plan_id
LEFT JOIN fact_expanded fe ON fe.resource_id = er.id AND fe.task_daily_plan_id = pe.task_daily_plan_id
WHERE tdp.task_id IS NOT NULL
GROUP BY tdp.task_id, tdp.task_section_id, er.id, er.name, er.unit_id, eu.short_name;

CREATE OR REPLACE VIEW materials_resource_plan_fact AS
WITH plan_expanded AS (
  SELECT mrp.task_daily_plan_id, mr.id AS resource_id, mrp.plan_qty
  FROM materials_resource_plan mrp
  JOIN materials_resource mr ON mr.id = mrp.resource_id
  WHERE mrp.status <> 'deprecated'
  UNION ALL
  SELECT mrp.task_daily_plan_id, mgr.resource_id, mrp.plan_qty
  FROM materials_resource_plan mrp
  JOIN materials_group_resource mgr ON mgr.group_id = mrp.group_id AND mgr.status <> 'deprecated'
  WHERE mrp.status <> 'deprecated' AND mrp.group_id IS NOT NULL
),
fact_expanded AS (
  SELECT mrf.task_daily_plan_id, mrf.resource_id, sum(mrf.fact_qty) AS fact_qty
  FROM materials_resource_fact mrf
  GROUP BY mrf.task_daily_plan_id, mrf.resource_id
)
SELECT
  tdp.task_id,
  tdp.task_section_id,
  mr.id AS resource_id,
  mr.name AS resource_name,
  mr.unit_id,
  mu.short_name AS unit_short_name,
  COALESCE(sum(pe.plan_qty), 0) AS plan_qty,
  COALESCE(max(fe.fact_qty), 0) AS fact_qty
FROM materials_resource mr
JOIN materials_unit mu ON mu.id = mr.unit_id
LEFT JOIN plan_expanded pe ON pe.resource_id = mr.id
LEFT JOIN task_daily_plan tdp ON tdp.id = pe.task_daily_plan_id
LEFT JOIN fact_expanded fe ON fe.resource_id = mr.id AND fe.task_daily_plan_id = pe.task_daily_plan_id
WHERE tdp.task_id IS NOT NULL
GROUP BY tdp.task_id, tdp.task_section_id, mr.id, mr.name, mr.unit_id, mu.short_name;

-- RLS для VIEW наследуется от базовых таблиц с security_invoker, чтобы политики RLS применялись
-- в контексте вызывающего пользователя, а не владельца VIEW.
ALTER VIEW personnel_resource_plan_fact SET (security_invoker = true);
ALTER VIEW equipment_resource_plan_fact SET (security_invoker = true);
ALTER VIEW materials_resource_plan_fact SET (security_invoker = true);
