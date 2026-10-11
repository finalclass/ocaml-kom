open Kom
open Kom.Schema

let init_cells =
  Flow.define
    {id= "init"; input= []; output= []; body= "!reproduce index as index"}

let add_task =
  Flow.define
    { id= "add_task"
    ; input=
        [("name", String); ("done", Optional Bool); ("priority", Optional Int)]
    ; output= Task_cell.task_props
    ; body=
        {|
    !transaction(!sequence(
      allocate @index
      !reproduce task as task.{$.task_id}
      add @task.{$.task_id}
      index @index
    ))
  |}
    }

let read_task =
  Flow.define
    { id= "read_task"
    ; input= [("task_id", String)]
    ; output= Task_cell.task_props
    ; body= "read @task.{$.task_id}" }

let list_tasks =
  Flow.define
    { id= "list_tasks"
    ; input= Index_cell.paging
    ; output= Index_cell.page_props
    ; body= "list @index" }

let list_finished_tasks =
  Flow.define
    { id= "list_finished_tasks"
    ; input=
        Index_cell.paging
        @ [("min_priority", Optional Int); ("max_priority", Optional Int)]
    ; output= Index_cell.page_props
    ; body= "finished @index" }

let update_task =
  Flow.define
    { id= "update_task"
    ; input= [("task_id", String); ("done", Bool); ("priority", Int)]
    ; output= Task_cell.task_props
    ; body= "!transaction(!sequence(update @task.{$.task_id} index @index))" }

let remove_task =
  Flow.define
    { id= "remove_task"
    ; input= [("task_id", String)]
    ; output= [("task_id", String)]
    ; body= "!transaction(!sequence(remove @task.{$.task_id} remove @index))" }

let definition =
  System.define
    ~cell_kinds:[Index_cell.cell; Task_cell.cell]
    ~init_flow:"init"
    ~flows:
      [ init_cells
      ; add_task
      ; read_task
      ; list_tasks
      ; list_finished_tasks
      ; update_task
      ; remove_task ]
    ()

let create ~sw ~domain_mgr ?(database = "todo.sqlite") () =
  System.create
    ~sw
    ~domain_mgr
    ~id:"todo"
    ~storage:(Kom_sqlite.storage database)
    definition
