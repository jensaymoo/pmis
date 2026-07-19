-- 042a_issue_work_order — RPC issue_work_order(work_order_id): created -> open, SECURITY DEFINER.
-- РЕШЕНИЕ ПО НУМЕРАЦИИ: roadmap/02-data-schema.md перечисляет эту миграцию как "019_issue_work_order"
-- в разделе 2.3 (RPC авторизации), но функция ссылается на таблицу work_order, которая физически
-- создаётся только в 040 (раздел 2.6). Помещаем файл здесь (042a, сразу после work_order_task
-- триггеров) — после того, как work_order и work_order_task гарантированно существуют.
-- Контракт (backend-fact-and-work-orders.md): проверка статуса = created; переход -> open;
-- RLS-проверка диспетчер в org_subtree() наряда. Ошибки: 400 (неверный статус), 403 (вне поддерева).
--
-- Примечание по сигнатуре: roadmap также упоминает issue_work_order(work_order_id, task_id) в
-- одном месте (2.3) и issue_work_order(work_order_id) без task_id в другом (backend-fact-and-work-
-- orders.md, единственная детализированная спецификация RPC). Выдача наряда — операция над
-- нарядом целиком (все его строки уже сформированы через work_order_task к моменту выдачи),
-- поэтому используется сигнатура backend-fact-and-work-orders.md: issue_work_order(work_order_id).

CREATE OR REPLACE FUNCTION issue_work_order(work_order_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_wo work_order%ROWTYPE;
BEGIN
  SELECT * INTO v_wo FROM work_order WHERE id = issue_work_order.work_order_id;

  IF NOT FOUND THEN
    RAISE sqlstate 'PT404' USING message = 'Наряд не найден';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM current_org_subtree() s WHERE s.id = v_wo.org_unit_id) THEN
    RAISE sqlstate 'PT403' USING message = 'Наряд вне зоны ответственности текущего пользователя';
  END IF;

  IF v_wo.status <> 'created' THEN
    RAISE sqlstate 'PT400' USING message = format('Выдать можно только наряд в статусе created (текущий статус: %s)', v_wo.status);
  END IF;

  UPDATE work_order SET status = 'open' WHERE id = v_wo.id;
END;
$$;

REVOKE ALL ON FUNCTION issue_work_order(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION issue_work_order(uuid) TO dispatcher;
