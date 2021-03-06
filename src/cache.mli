open Core.Std

type ('a, 'b) t

val create : unit -> ('a, 'b) t
val get : ('a, 'b) t -> key:string -> exp:float -> thunk:(unit ->  ('a, 'b) Result.t Lwt.t) -> ('a, 'b) Result.t Lwt.t
val invalidate : ('a, 'b) t -> string -> unit
