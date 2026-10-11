module Files = struct
  type t = File_access.t

  let read = File_access.read

  let write = File_access.write

  let delete = File_access.delete

  let list = File_access.list
end

module Web = Web
module App = App

module Plugin = struct
  let register = Plugin_access.register
end

module Runtime = struct
  include Runtime_manager

  let serve = Server.run
end
