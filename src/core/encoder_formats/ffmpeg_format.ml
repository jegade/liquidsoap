(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2023 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

type opt_val =
  [ `String of string | `Int of int | `Int64 of int64 | `Float of float ]

type copy_opt = [ `Wait_for_keyframe | `Ignore_keyframe ]
type output = [ `Stream | `Url of string ]
type opts = (string, opt_val) Hashtbl.t
type hwaccel = [ `None | `Auto ]

type audio_options = {
  channels : int;
  samplerate : int Lazy.t;
  sample_format : string option;
}

type video_options = {
  framerate : int Lazy.t;
  width : int Lazy.t;
  height : int Lazy.t;
  pixel_format : string option;
  hwaccel : hwaccel;
  hwaccel_device : string option;
}

type options = [ `Audio of audio_options | `Video of video_options ]

type encoded_stream = {
  mode : [ `Raw | `Internal ];
  codec : string option;
  options : options;
  opts : opts;
}

type stream = [ `Copy of copy_opt | `Encode of encoded_stream ]

type t = {
  format : string option;
  output : output;
  streams : (Frame.field * stream) list;
  opts : opts;
}

let string_of_options
    (options : (string, [< `Var of string | opt_val ]) Hashtbl.t) =
  let _v = function
    | `Var v -> v
    | `String s -> Printf.sprintf "%S" s
    | `Int i -> string_of_int i
    | `Int64 i -> Int64.to_string i
    | `Float f -> string_of_float f
  in
  String.concat ","
    (Hashtbl.fold
       (fun k v c ->
         let v = Printf.sprintf "%s=%s" k (_v v) in
         v :: c)
       options [])

let string_of_copy_opt = function
  | `Wait_for_keyframe -> "wait_for_keyframe"
  | `Ignore_keyframe -> "ignore_keyframe"

let to_string m =
  let opts = [] in
  let opts =
    if Hashtbl.length m.opts > 0 then string_of_options m.opts :: opts else opts
  in
  let opts =
    List.fold_left
      (fun opts (field, stream) ->
        let name = Frame.Fields.string_of_field field in
        let name =
          match stream with
            | `Copy _ -> "%" ^ name ^ ".copy"
            | `Encode { mode = `Raw } -> "%" ^ name ^ ".raw"
            | _ -> "%" ^ name
        in
        match stream with
          | `Copy opt ->
              Printf.sprintf "%s(%s)" name (string_of_copy_opt opt) :: opts
          | `Encode { codec; options = `Video options; opts = stream_opts } ->
              let stream_opts =
                Hashtbl.fold
                  (fun lbl v h ->
                    Hashtbl.add h lbl (v :> [ `Var of string | opt_val ]);
                    h)
                  stream_opts (Hashtbl.create 10)
              in
              ignore
                (Option.map
                   (fun codec ->
                     Hashtbl.add stream_opts "codec" (`String codec))
                   codec);
              Hashtbl.add stream_opts "framerate"
                (`Int (Lazy.force options.framerate));
              Hashtbl.add stream_opts "width" (`Int (Lazy.force options.width));
              Hashtbl.add stream_opts "height"
                (`Int (Lazy.force options.height));
              Hashtbl.add stream_opts "hwaccel"
                (`Var
                  (match options.hwaccel with
                    | `None -> "none"
                    | `Auto -> "auto"));
              Hashtbl.add stream_opts "hwaccel_device"
                (match options.hwaccel_device with
                  | None -> `Var "none"
                  | Some d -> `String d);
              Printf.sprintf "%%%s(%s%s)" name
                (if Pcre.pmatch ~pat:"video" name then "" else "video_content,")
                (string_of_options stream_opts)
              :: opts
          | `Encode { codec; options = `Audio options; opts = stream_opts } ->
              let stream_opts = Hashtbl.copy stream_opts in
              ignore
                (Option.map
                   (fun codec ->
                     Hashtbl.add stream_opts "codec" (`String codec))
                   codec);
              Hashtbl.add stream_opts "channels" (`Int options.channels);
              Hashtbl.add stream_opts "samplerate"
                (`Int (Lazy.force options.samplerate));
              Printf.sprintf "%s(%s%s)" name
                (if Pcre.pmatch ~pat:"audio" name then "" else "audio_content,")
                (string_of_options stream_opts)
              :: opts)
      opts m.streams
  in
  let opts =
    match m.format with
      | Some f -> Printf.sprintf "format=%S" f :: opts
      | None -> opts
  in
  Printf.sprintf "%%ffmpeg(%s)" (String.concat "," opts)
