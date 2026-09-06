let static_root = "static"
let audio_file = "audio.webm"

(* The client already serializes its uploads, but chunks must be appended in
   order: only the first one carries the WebM header, the rest are bare cluster
   continuations. *)
let audio_mutex = Lwt_mutex.create ()

let with_audio_file flags f =
  Lwt_mutex.with_lock audio_mutex (fun () ->
      Lwt_io.with_file ~flags ~mode:Lwt_io.Output audio_file f)

let () =
  Dream.run
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.get "/" (fun request ->
             Dream.from_filesystem static_root "index.html" request);
         Dream.post "/record/start" (fun _ ->
             let%lwt () =
               with_audio_file
                 [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
                 (fun _ -> Lwt.return_unit)
             in
             Dream.respond "");
         Dream.post "/record/chunk" (fun request ->
             let%lwt chunk = Dream.body request in
             let%lwt () =
               with_audio_file
                 [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
                 (fun oc -> Lwt_io.write oc chunk)
             in
             Dream.respond "");
         Dream.get "/**" (Dream.static static_root);
       ]
