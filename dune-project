(lang dune 3.14)

(generate_opam_files true)

(name webrtc)
(source (github smimram/ocaml-webrtc))
(license LGPL-2.1-or-later)
(authors "Samuel Mimram <smimram@gmail.com>")
(maintainers "Samuel Mimram <smimram@gmail.com>")

(package
 (name webrtc)
 (synopsis "WebRTC transport stack in OCaml")
 (description
  "The pieces a WebRTC endpoint is made of, none of which exists in opam:\
\nSDP, ICE and STUN, DTLS with the SRTP key exchange, SRTP itself, RTP with\
\nthe VP8, VP9 and H.264 payload formats, and Ogg/Opus and Matroska muxers\
\nwhich store a peer's packets bit-exact.")
 (depends
  (ocaml (>= 4.14))
  digestif
  ipaddr
  mirage-crypto
  mirage-crypto-ec
  (mirage-crypto-rng (>= 1.0.0))
  ptime
  tls
  x509))

(package
 (name recrtc)
 ; Nothing is installed: this package exists to record the example's own
 ; dependencies.
 (allow_empty)
 (synopsis "Record what a browser sends over WebRTC as an Ogg/Opus or Matroska file")
 (description
  "A web server which records the audio and video a browser sends it over\
\nWebRTC, as an example of what the webrtc libraries can be used for.")
 (depends
  (ocaml (>= 4.14))
  webrtc
  dream
  lwt
  lwt_ppx
  (mirage-crypto-rng (>= 1.0.0))))

(package
 (name conference)
 ; Nothing is installed: this package exists to record the example's own
 ; dependencies.
 (allow_empty)
 (synopsis "A WebRTC conferencing server: one speaker, many attendees")
 (description
  "A selective forwarding unit and the pages that drive it: a speaker sends\
\nmicrophone, camera and desktop once, and the server forwards the packets to\
\neveryone watching, as an example of what the webrtc libraries can be used\
\nfor.")
 (depends
  (ocaml (>= 4.14))
  webrtc
  dream
  lwt
  lwt_ppx
  (mirage-crypto-rng (>= 1.0.0))))
