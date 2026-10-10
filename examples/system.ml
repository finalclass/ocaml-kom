open Kom
open Kom.Schema

let init_cells =
  Flow.define
    { id= "init"
    ; input= []
    ; output= []
    ; body=
        {|
    !sequence(
      !reproduce index as index
      !reproduce task_ids_expander as task_ids_expander
      !reproduce tasks_collector as tasks_collector
    )
  |}
    }

let add_task =
  Flow.define
    { id= "add_task"
    ; input= [("name", String)]
    ; output= Task_cell.task_props
    ; body=
        {|
    !sequence(
      allocate @index
      !reproduce task as task.{$.task_id}
      add @task.{$.task_id}
      index @index
    )
  |}
    }

let read_task =
  Flow.define
    { id= "read_task"
    ; input= [("task_id", String)]
    ; output= Task_cell.task_props
    ; body= {|
    read @task.{$.task_id}
  |} }

let list_tasks =
  Flow.define
    { id= "list_tasks"
    ; input= []
    ; output= [("tasks", List (Object Task_cell.task_props))]
    ; body=
        {|
    !sequence(
      list @index
      expand @task_ids_expander
      !parallel_each(
        read @task.{$.task_id}
      )
      collect @tasks_collector
    )
  |}
    }

let remove_task =
  Flow.define
    { id= "remove_task"
    ; input= [("task_id", String)]
    ; output= [("task_id", String)]
    ; body=
        {|
    !sequence(
      remove @index
      remove @task.{$.task_id}
    )
  |}
    }

let definition =
  System.define
    ~cell_kinds:
      [ Index_cell.cell
      ; Task_cell.cell
      ; Task_ids_expander_cell.cell
      ; Tasks_collector_cell.cell ]
    ~init_flow:"init"
    ~flows:[init_cells; add_task; read_task; list_tasks; remove_task]
    ()

let create ~sw ~domain_mgr ?(database = "todo.sqlite") () =
  System.create ~sw ~domain_mgr ~id:"todo" ~storage:(Kom_sqlite.storage database) definition
