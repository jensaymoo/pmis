-- 042b_cancel_work_order — RPC cancel_work_order(work_order_id): created/open -> canceled,
-- SECURITY DEFINER. БЕЗ каскадного удаления work_order_task/work_order_task_fact — строки
-- остаются, факт не создаётся (ВАРИАНТ C, backend-fact-and-work-orders.md).
-- РЕШЕНИЕ ПО НУМЕРАЦИИ: см. комментарий в 042a_issue_work_order.sql — перенесено с "020" сюда
-- по той же причине (зависимость от work_order, физически созданной в 040).

CREATE OR REPLACE FUNCTION cancel_work_order(work_order_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_wo work_order%ROWTYPE;
BEGIN
  SELECT * INTO v_wo FROM work_order WHERE id = cancel_work_order.work_order_id;

  IF NOT FOUND THEN
    RAISE sqlstate 'PT404' USING message = 'Наряд не найден';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM current_org_subtree() s WHERE s.id = v_wo.org_unit_id) THEN
    RAISE sqlstate 'PT403' USING message = 'Наряд вне зоны ответственности текущего пользователя';
  END IF;

  IF v_wo.status NOT IN ('created', 'open') THEN
    RAISE sqlstate 'PT400' USING message = format('Аннулировать можно только наряд в статусе created или open (текущий статус: %s)', v_wo.status);
  END IF;

  UPDATE work_order SET status = 'canceled' WHERE id = v_wo.id;
  -- work_order_task и его строки НЕ трогаем (ВАРИАНТ C) — остаются как есть, факт не создаётся.
END;
$$;

REVOKE ALL ON FUNCTION cancel_work_order(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cancel_work_order(uuid) TO dispatcher;
