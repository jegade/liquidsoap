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

open Source

class available ~track_sensitive ~override p (source : source) =
  object
    inherit operator ~name:"source.available" [source]
    method stype = `Fallible
    method remaining = source#remaining
    method abort_track = source#abort_track
    method seek = source#seek
    method self_sync = source#self_sync
    val mutable ready = p ()

    method is_ready =
      if not (track_sensitive () && ready) then ready <- p ();
      ready && (override || source#is_ready)

    method private get_frame buf =
      source#get buf;
      if track_sensitive () && Frame.is_partial buf then ready <- p ()
  end

let _ =
  let return_t = Lang.frame_t (Lang.univ_t ()) Frame.Fields.empty in
  Lang.add_operator ~base:Muxer.source "available"
    [
      ( "track_sensitive",
        Lang.getter_t Lang.bool_t,
        Some (Lang.bool false),
        Some "Change availability only on end of tracks." );
      ( "override",
        Lang.bool_t,
        Some (Lang.bool false),
        Some
          "Don't take availability of original source in account (this can be \
           dangerous and should be avoided)." );
      ( "",
        Lang.source_t return_t,
        None,
        Some "Source of which the availability should be changed." );
      ( "",
        Lang.getter_t Lang.bool_t,
        None,
        Some
          "Predicate indicating whether the source should be available or not."
      );
    ]
    ~category:`Track
    ~descr:"Change the availability of a source depending on a predicate."
    ~return_t
    (fun p ->
      let track_sensitive =
        List.assoc "track_sensitive" p |> Lang.to_bool_getter
      in
      let override = List.assoc "override" p |> Lang.to_bool in
      let s = Lang.assoc "" 1 p |> Lang.to_source in
      let pred = Lang.assoc "" 2 p |> Lang.to_bool_getter in
      new available ~track_sensitive ~override pred s)
