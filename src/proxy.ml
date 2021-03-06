open Core.Std
open Lwt
open Cohttp_lwt_unix
open Har_j
open Settings

type protocol = HTTP | HTTPS
exception Too_many_requests
exception Cant_resolve_ip of string * string

let make_server config =
  let nb_current = ref 0 in
  let module Socket = Socket.Make (struct
    let host = config.zmq_host
    let port = config.zmq_port
  end) in
  let global_archive = Option.map ~f:(fun k -> (module Archive.Make (struct let key = k end) : Archive.Sig_make)) config.key in
  let empty_archive = Some (module Archive.Make (struct let key = "" end) : Archive.Sig_make) in

  let send_har archive environment req req_uri req_headers res t_client_body t_provider_body client_ip server_ip (t0, har_send, har_wait) =
    let send () = try_lwt (
        t_client_body
      >>= fun (req_length, req_b64) ->
        t_provider_body
      >>= fun (res_length, res_b64) ->
        let module KeyArchive = (val archive : Archive.Sig_make) in

        (* Bypass for XHR *)
        if KeyArchive.key = "" then return_unit else

        let archive_input = Archive.({
          environment;
          req;
          req_uri;
          req_headers;
          res;
          req_length;
          res_length;
          req_b64;
          res_b64;
          client_ip;
          server_ip;
          timings = (har_send, har_wait, ((get_timestamp_ms ()) - t0 - har_wait));
        }) in

        let har_string = KeyArchive.get_alf archive_input |> string_of_alf |> fun x -> Printf.sprintf "%s %s" Settings.alf_version x in
        Socket.send har_string >>= function
        | Ok _ ->
          if config.debug then Lwt_io.printlf "SENT\n%s\n" har_string
          else return_unit
        | Error err_str ->
          ignore (Lwt_io.printl err_str);
          return_unit
    ) with ex ->
      match ex with
      | e ->
        Lwt_io.printlf "ERROR\n%s\n%s" (Exn.to_string e) (Exn.backtrace ())
    in
    match config.filter_ua with
    | None -> send ()
    | Some filter when Cohttp.Header.get (Request.headers req) "User-Agent" |> Option.value ~default:"" |> Regex.matches filter |> not -> send ()
    | Some _ -> return_unit
  in
  let callback (ch, _) req client_body protocol =
    (* Initiate counters and other bookeeping *)
    nb_current := (!nb_current + 1);
    let t0 = Archive.get_timestamp_ms () in
    let client_headers = Request.headers req in
    let client_ip = Http_utils.get_header_ip client_headers |> Option.value ~default:(Network.get_addr_from_ch ch) in
    let client_headers_ready = Http_utils.sanitize_headers client_headers client_ip in
    let environment = Option.first_some (Cohttp.Header.get client_headers "Mashape-Environment") config.environment in

    let uri = Request.uri req
    |> fun uri ->
      match Cohttp.Header.get client_headers "Mashape-Host-Override" with
      | None -> uri
      | Some x -> Uri.with_host uri (Some x)
    in

    (* Prepare the target *)
    let target = (match config.reverse with
    | None -> uri
    | Some (reverse_host, reverse_port) ->
      uri
      |> fun uri -> Uri.with_host uri reverse_host
      |> fun uri ->
        match reverse_port with
        | Some p -> Uri.with_port uri p
        | None -> uri
    ) |> fun uri ->
      let protocol_header = (Option.first_some
        (Cohttp.Header.get client_headers "Mashape-Upstream-Protocol")
        (Cohttp.Header.get client_headers "X-Forwarded-Proto"))
      |> Option.map ~f:String.lowercase
      in
      match (protocol_header, protocol) with
      | (Some "https", _) | (None, HTTPS) -> Uri.with_scheme uri (Some "https")
      | (Some "http", _) | (None, HTTP) | (Some _, _) -> Uri.with_scheme uri (Some "http")
    in

    (* This is the URI used to generate the ALF. Same as target, except that it doesn't contain the Host/Target/IP manipulations *)
    let uri_fixed = Uri.with_scheme uri (Uri.scheme target) in

    (* Debug output *)
    ignore (if config.debug then
      Lwt_io.printlf "RECEIVED %s\n> protocol: %s\n> host: %s\n> port: %s\n> path: %s\n"
        (Uri.to_string target)
        (Uri.scheme target |> Option.value ~default:"<<no protocol>>")
        (Uri.host target |> Option.value ~default:"<<no host>>")
        (Uri.port target |> Option.map ~f:Int.to_string |> Option.value ~default:"<<no port>>")
        (Uri.path target)
      else return_unit);

    (* Start fetching the target IP in advance *)
    let target_to_resolve = target |> Uri.host |> Option.value ~default:"" in
    let t_dns = Network.dns_lookup target_to_resolve in

    (* More bookeeping *)
    let t_client_body = Http_utils.process_body client_body config.replays in
    let local_archive = Option.map (Cohttp.Header.get client_headers "Mashape-Service-Token") ~f:(fun k ->
      (module Archive.Make (struct let key = k end) : Archive.Sig_make)) in
    let har_send = (Archive.get_timestamp_ms ()) - t0 in

    (* Main block. Throws lwt exceptions for any invalid request or error *)
    let response = try_lwt (
      (* Throw some exceptions if needed, then set some headers *)
      if !nb_current > config.concurrent then Lwt.fail Too_many_requests else

    (* OPTIONS calls are used for CORS requests and should go through even without a service-token *)
      let archive = match Request.meth req with
      | `OPTIONS -> Option.first_some local_archive empty_archive
      | _ -> Option.first_some local_archive global_archive
      in

      match archive with
      | None ->
        Lwt.fail (Failure "Mashape-Service-Token header missing")
      | Some archive ->
        (* Do the remote call using the prefetched cached IP. The whole thing has a Lwt.pick timeout *)
        let remote_call = (
            t_dns
          >>= function
            | Error e -> Lwt.fail (Cant_resolve_ip (e, target_to_resolve))
            | Ok server_ip ->
              let chunked = match Request.encoding req with
              | Cohttp.Transfer.Fixed _ | Cohttp.Transfer.Unknown -> false
              | Cohttp.Transfer.Chunked -> true
              in
              Client.call ~headers:client_headers_ready ~chunked ~body:client_body (Request.meth req) (Uri.with_host target (Some server_ip))
          >>= fun (res, provider_body) ->
            let har_wait = (Archive.get_timestamp_ms ()) - t0 - har_send in
            let t_provider_body = Http_utils.process_body provider_body config.replays in
            ignore (send_har archive environment req uri_fixed client_headers_ready res t_client_body t_provider_body client_ip server_ip (t0, har_send, har_wait));
            let provider_headers = Response.headers res in

            (* Make the response manually to choose the right Encoding *)
            let client_response = Response.make ~version:(Response.version res) ~status:(Response.status res) ~encoding:(Response.encoding res) ~headers:provider_headers () in
            return (client_response, provider_body)
        )
        in
        Lwt.pick [remote_call; Lwt_unix.timeout config.timeout]
    ) with ex ->
      let (error_code, error_text) = match ex with
      | Lwt_unix.Timeout ->
        (504, "504: The server timed out trying to establish a connection")
      | Too_many_requests ->
        (429, "429: The server is under heavy load, try again")
      | Cant_resolve_ip (err, host) ->
        (400, Printf.sprintf "400: Hostname cannot be resolved %s (%s)" err host)
      | _ ->
        (500, Printf.sprintf "500: %s" (Exn.to_string ex))
      in
      let har_wait = (Archive.get_timestamp_ms ()) - t0 - har_send in
      let t_res =
        Lwt_unix.sleep Settings.http_error_wait
        >>= fun () ->
          Server.respond_error ~status:(Cohttp.Code.status_of_code error_code) ~body:error_text ()
      in
      ignore (t_res >>= fun (res, provider_body) ->
        let t_provider_body = Http_utils.process_body provider_body config.replays in
        match Option.first_some local_archive global_archive with
        | None -> return_unit
        | Some archive ->
          t_dns
          >>= function
          | Error server_ip | Ok server_ip ->
            send_har archive environment req uri_fixed client_headers_ready res t_client_body t_provider_body client_ip server_ip (t0, har_send, har_wait)
      );
      t_res
    in
    ignore (response >>= fun _ -> return (nb_current := (!nb_current - 1)));
    response
  in
  (* This is necessary so that critical bugs don't end up taking up all the concurrency *)
  let wrapped_callback = fun c r b p ->
    try_lwt (callback c r b p) with ex ->
      nb_current := (!nb_current - 1);
      let error_text = Exn.to_string ex in
      ignore (Lwt_io.printlf "Something bad happened .Error: %s\n" error_text);
      Server.respond_error ~status:(Cohttp.Code.status_of_code 500) ~body:error_text ()
  in
  let conn_closed (_, _) = () in
  let config_tcp = Server.make ~callback:(fun c r b -> wrapped_callback c r b HTTP) ~conn_closed () in
  let config_ssl = Server.make ~callback:(fun c r b -> wrapped_callback c r b HTTPS) ~conn_closed () in
  let ctx = Cohttp_lwt_unix_net.init () in
  let tcp_mode = `TCP (`Port config.port) in
  let tcp_server = Server.create ~ctx ~mode:tcp_mode config_tcp in
  ignore (Lwt_io.printf "HTTP server listening on port %n\n" config.port);
  match config.https with
  | None ->
    tcp_server
  | Some https_port ->
    let ssl_mode = `OpenSSL (`Crt_file_path "cert.pem", `Key_file_path "key.pem", `No_password, `Port https_port) in
    let start_https_thunk () = Server.create ~ctx ~mode:ssl_mode config_ssl in
    match Result.try_with start_https_thunk with
    | Ok ssl_server ->
      ignore (Lwt_io.printf "HTTPS server listening on port %n\n" https_port);
      (tcp_server <&> ssl_server)
    | Error e ->
      ignore (Lwt_io.printf "An HTTPS error occured. Make sure both cert.pem and key.pem are located in the current harchiver directory\n%s\nOnly HTTP mode was started\n\n" (Exn.to_string e));
      tcp_server
