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

(** Decode raw ffmpeg frames. *)

let mk_decoder ~stream_idx ~stream_time_base ~mk_params ~lift_data ~put_data
    params =
  let duration_converter =
    Ffmpeg_utils.Duration.init ~src:stream_time_base
      ~get_ts:Ffmpeg_utils.best_pts
  in
  fun ~buffer frame ->
    match Ffmpeg_utils.Duration.push duration_converter frame with
      | Some (length, frames) ->
          let data =
            List.map
              (fun (pos, frame) ->
                ( pos,
                  {
                    Ffmpeg_raw_content.time_base = stream_time_base;
                    stream_idx;
                    frame;
                  } ))
              frames
          in
          let data =
            { Ffmpeg_content_base.params = mk_params params; data; length }
          in
          let data = lift_data data in
          put_data buffer.Decoder.generator data
      | None -> ()

let mk_audio_decoder ~stream_idx ~format ~stream ~field params =
  Ffmpeg_decoder_common.set_audio_stream_decoder stream;
  ignore
    (Content.merge format
       Ffmpeg_raw_content.(Audio.lift_params (AudioSpecs.mk_params params)));
  let stream_time_base = Av.get_time_base stream in
  let lift_data data = Ffmpeg_raw_content.Audio.lift_data data in
  let mk_params = Ffmpeg_raw_content.AudioSpecs.mk_params in
  mk_decoder ~stream_idx ~lift_data ~mk_params ~stream_time_base
    ~put_data:(fun g c -> Generator.put g field c)
    params

let mk_video_decoder ~stream_idx ~format ~stream ~field params =
  Ffmpeg_decoder_common.set_video_stream_decoder stream;
  ignore
    (Content.merge format
       Ffmpeg_raw_content.(Video.lift_params (VideoSpecs.mk_params params)));
  let stream_time_base = Av.get_time_base stream in
  let lift_data data = Ffmpeg_raw_content.Video.lift_data data in
  let mk_params = Ffmpeg_raw_content.VideoSpecs.mk_params in
  mk_decoder ~stream_idx ~mk_params ~lift_data ~stream_time_base
    ~put_data:(fun g c -> Generator.put g field c)
    params
