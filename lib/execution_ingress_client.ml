let register bus execution = Message_bus.register bus
  ~work:(fun () -> Execution_manager.tick execution)
  ~admission:(fun () -> Execution_manager.admit_buffer execution)
