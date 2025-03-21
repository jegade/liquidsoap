include Liquidsoap_lang.Lang
include Lang_source
include Lang_encoder.L
module Doc = Liquidsoap_lang.Doc

(** Helpers for defining protocols. *)

let add_protocol ~syntax ~doc ~static name resolver =
  Doc.Protocol.add ~name ~doc ~syntax ~static;
  let spec = { Request.static; resolve = resolver } in
  Plug.register Request.protocols ~doc name spec

let frame_t base_type fields = Frame_type.make base_type fields
let internal_t () = Frame_type.internal ()

let format_t t =
  Type.make
    (Type.Constr
       (* The type has to be invariant because we don't want the sup mechanism to be used here, see #2806. *)
       { Type.constructor = "format"; Type.params = [(`Invariant, t)] })

module HttpTransport = struct
  include Value.MkAbstract (struct
    type content = Http.transport

    let name = "http_transport"

    let to_json ~pos _ =
      Runtime_error.raise ~pos
        ~message:"Http transport cannot be represented as json" "json"

    let descr transport = Printf.sprintf "<%s_transport>" transport#name
    let compare = Stdlib.compare
  end)

  let meths =
    [
      ( "name",
        ([], string_t),
        "Transport name",
        fun transport -> string transport#name );
      ( "protocol",
        ([], string_t),
        "Transport protocol",
        fun transport -> string transport#protocol );
      ( "default_port",
        ([], int_t),
        "Transport default port",
        fun transport -> int transport#default_port );
    ]

  let t =
    method_t t (List.map (fun (lbl, t, descr, _) -> (lbl, t, descr)) meths)

  let to_value transport =
    meth (to_value transport)
      (List.map (fun (lbl, _, _, m) -> (lbl, m transport)) meths)
end

let http_transport_t = HttpTransport.t
let to_http_transport = HttpTransport.of_value
let http_transport = HttpTransport.to_value
