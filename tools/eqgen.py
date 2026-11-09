#!/usr/bin/env python3
"""eqgen.py -- the PipeWire equaliser behind tools/eq.sh (run eq.sh, not this).

  eqgen.py import LAYOUT.xml.zlib OUT.json
      Read Apple's speaker processing from a copy of macOS's AppleHDA layout file for this
      iMac (layout16.xml.zlib) and save the parts used here (EQ filters, levels, tweeter
      delay) to OUT.json. The file is Apple's: OUT.json stays on your machine.
  eqgen.py conf BASS TREBLE LOUDNESS TARGET NAME [TUNING.json]
      Print the PipeWire config (filter-chain sink NAME in front of the sink TARGET).
  eqgen.py params BASS TREBLE LOUDNESS [TUNING.json]
      Print the control values for a live change (pw-cli set-param ... Props).

Without a tuning file: the simple equaliser (bass shelf on the woofers, treble shelf on the
tweeters, low cuts, level compensation, limiters). With one: Apple's own chain for the
internal speakers -- input EQ, levels, the 2-to-4 split with each speaker pair's EQ and
crossover, and the tweeter delay -- computed as exact biquads, plus the same bass, treble
and loudness controls and limiters. Apple's dynamic stages (compressors, loudness contour,
"BuzzKill") are not reproduced; the loudness control and limiters stand in for them.
"""
import hashlib, json, math, plistlib, re, struct, sys, zlib

RATES = (44100, 48000)
LIMPLUG = "fast_lookahead_limiter_1913"
LIMIT, RELEASE = -1.0, 0.3

# ---------------------------------------------------------------- Apple layout import
EXPECT = ["DspEqualization32", "DspMozartCompressor", "DspLoudness", "DspMozartCompressorDualBand",
          "DspGainStage", "Dsp2To4Splitter", "DspGainStage", "DspGainStage", "DspEqualization32",
          "DspEqualization32", "DspBuzzKill", "DspDelay", "DspControlFreak4ch", "Dsp4ChOutput"]
# (function, input port) -> (source function, source port), as in layout 16
EXPECT_LINKS = {(1, 0): (0, 0), (1, 1): (0, 1), (2, 0): (1, 0), (2, 1): (1, 1), (3, 0): (2, 0),
                (3, 1): (2, 1), (4, 0): (3, 0), (4, 1): (3, 1), (5, 0): (4, 0), (5, 1): (4, 1),
                (6, 0): (5, 0), (6, 1): (5, 1), (7, 0): (5, 2), (7, 1): (5, 3), (8, 0): (6, 0),
                (8, 1): (6, 1), (9, 0): (7, 0), (9, 1): (7, 1), (10, 0): (8, 0), (10, 1): (8, 1),
                (11, 0): (9, 0), (11, 1): (9, 1), (12, 0): (11, 0), (12, 1): (11, 1),
                (12, 2): (10, 0), (12, 3): (10, 1), (13, 0): (12, 0), (13, 1): (12, 1),
                (13, 2): (12, 2), (13, 3): (12, 3)}
FTYPES = {0: "lowpass", 1: "highpass", 4: "peaking"}


def f32(i):
    return struct.unpack("<f", struct.pack("<i", i))[0]


def import_layout(path, out):
    raw = open(path, "rb").read()
    try:
        x = zlib.decompress(raw)
    except zlib.error:
        x = raw
    x = re.sub(rb"<!--.*?-->", b"", x, flags=re.S)
    if not x.lstrip().startswith(b"<?xml"):
        x = b'<?xml version="1.0"?><plist version="1.0">' + x + b"</plist>"
    try:
        p = plistlib.loads(x)
        pm = p["PathMapRef"][0]
        sd = pm["IntSpeaker"]["SignalProcessing"][0]["SoftwareDSP"]
    except Exception:
        sys.exit("ERROR: this isn't an AppleHDA layout file with speaker processing (expected layout16.xml.zlib)")
    if p.get("LayoutID") != 16:
        sys.exit(f"ERROR: this is layout {p.get('LayoutID')}, not 16 (the iMac19,1 layout)")
    if 0x10138409 not in pm.get("CodecID", []):
        sys.exit("ERROR: this layout isn't for the CS8409 codec")
    F = {sd[k]["FunctionInfo"]["DspFuncInstance"]: sd[k] for k in sd}
    names = [F[i]["FunctionInfo"]["DspFuncName"] for i in sorted(F)]
    if names != EXPECT:
        sys.exit("ERROR: the speaker processing in this file isn't laid out as expected:\n  " + ", ".join(names))
    for i, fn in F.items():
        for port in fn.get("PatchbayInfo", {}).values():
            if EXPECT_LINKS.get((i, port["PortInstance"])) != (port["SourceFuncInstance"], port["SourcePortIndex"]):
                sys.exit(f"ERROR: unexpected connection into stage {i}; not importing")

    def filters(fi, ch):
        out_ = []
        for e in F[fi]["ParameterInfo"]["Filter"]:
            if e["2"] != ch:
                continue
            if e["5"] not in FTYPES:
                sys.exit(f"ERROR: unknown filter type {e['5']} in stage {fi}")
            out_.append({"type": FTYPES[e["5"]], "freq": round(f32(e["6"]), 4),
                         "q": round(f32(e["7"]), 5), "gain": round(f32(e["8"]), 4)})
        return out_

    db = lambda v: round(20 * math.log10(v), 4)
    gain = lambda fi, ch: db(f32(F[fi]["ParameterInfo"][str(ch + 2)]))
    t = {"source": "AppleHDA layout16 (macOS), IntSpeaker SoftwareDSP",
         "source_sha256": hashlib.sha256(raw).hexdigest(),
         "input_eq": [filters(0, 0), filters(0, 1)],
         "input_gain_db": [gain(4, 0), gain(4, 1)],
         # splitter ports 0/1 -> stage 6 -> EQ 8 -> BuzzKill -> outputs 2/3 (woofers)
         "woofer_gain_db": [gain(6, 0), gain(6, 1)],
         "woofer_eq": [filters(8, 0), filters(8, 1)],
         # splitter ports 2/3 -> stage 7 -> EQ 9 -> delay -> outputs 0/1 (tweeters)
         "tweeter_gain_db": [gain(7, 0), gain(7, 1)],
         "tweeter_eq": [filters(9, 0), filters(9, 1)],
         "tweeter_delay_samples": int(F[11]["ParameterInfo"]["2"])}
    json.dump(t, open(out, "w"), indent=1)
    n = sum(len(t[k][c]) for k in ("input_eq", "woofer_eq", "tweeter_eq") for c in (0, 1))
    print(f"Imported Apple's speaker tuning: {n} filters, tweeter delay {t['tweeter_delay_samples']} samples.")


# ---------------------------------------------------------------- filters
def rbj(ftype, f0, q, g, fs):
    """RBJ audio-EQ-cookbook biquad, normalised (a0 = 1)."""
    A = 10 ** (g / 40)
    w = 2 * math.pi * f0 / fs
    c, s = math.cos(w), math.sin(w)
    al = s / (2 * q)
    if ftype == "lowpass":
        b, a = [(1 - c) / 2, 1 - c, (1 - c) / 2], [1 + al, -2 * c, 1 - al]
    elif ftype == "highpass":
        b, a = [(1 + c) / 2, -(1 + c), (1 + c) / 2], [1 + al, -2 * c, 1 - al]
    elif ftype == "peaking":
        b, a = [1 + al * A, -2 * c, 1 - al * A], [1 + al / A, -2 * c, 1 - al / A]
    else:
        raise ValueError(ftype)
    return [v / a[0] for v in b], [1.0, a[1] / a[0], a[2] / a[0]]


def raw_node(name, flt):
    co = []
    for fs in RATES:
        b, a = rbj(flt["type"], flt["freq"], flt["q"], flt["gain"], fs)
        co.append(f'{{ rate = {fs} b0 = {b[0]:.12g} b1 = {b[1]:.12g} b2 = {b[2]:.12g} '
                  f'a0 = 1.0 a1 = {a[1]:.12g} a2 = {a[2]:.12g} }}')
    return (f'{{ type = builtin name = {name} label = bq_raw  # {flt["type"]} {flt["freq"]:.1f} Hz '
            f'Q {flt["q"]:.2f} {flt["gain"]:+.1f} dB\n'
            f'            config = {{ coefficients = [ {" ".join(co)} ] }} }}')


def gain_node(name, db):
    return f'{{ type = builtin name = {name} label = bq_highshelf control = {{ "Freq" = 0.0 "Q" = 1.0 "Gain" = {db:.2f} }} }}'


def lim_node(name, loud):
    return (f'{{ type = ladspa  name = {name} plugin = {LIMPLUG} label = fastLookaheadLimiter\n'
            f'            control = {{ "Input gain (dB)" = {loud:.1f} "Limit (dB)" = {LIMIT} '
            f'"Release time (s)" = {RELEASE} }} }}')


# ---------------------------------------------------------------- graphs
def levels(bass, treble, tuning):
    """Level of each speaker pair before its shelf, per side: boosts never raise the peak."""
    if tuning is None:   # simple: woofers 3 dB below tweeters, 1 dB headroom (measured)
        tw = -1 - max(treble, 0)
        wf = -4 - max(bass - 3, 0)
        return [tw, tw], [wf, wf]
    # Apple: its chain peaks about 7 dB below full scale, so only bigger boosts need room
    tw = [tuning["tweeter_gain_db"][c] - max(treble - 6, 0) for c in (0, 1)]
    wf = [tuning["woofer_gain_db"][c] - max(bass - 6, 0) for c in (0, 1)]
    return tw, wf


def graph_id(tuning):
    return "3-simple" if tuning is None else "3-apple-" + tuning["source_sha256"][:12]


def conf(bass, treble, loud, target, name, tuning):
    tw, wf = levels(bass, treble, tuning)
    nodes, links = [], []

    def chain(seq):
        for a, b in zip(seq, seq[1:]):
            links.append(f'{{ output = "{a[0]}:{a[2]}" input = "{b[0]}:{b[1]}" }}')

    for c, X in ((0, "L"), (1, "R")):
        nodes.append(f'{{ type = builtin name = in{X} label = copy }}')
        pre = [(f"in{X}", "In", "Out")]
        if tuning:
            for k, flt in enumerate(tuning["input_eq"][c]):
                nodes.append(raw_node(f"ap_in_{X}{k}", flt)); pre.append((f"ap_in_{X}{k}", "In", "Out"))
            nodes.append(gain_node(f"ap_pre_{X}", tuning["input_gain_db"][c])); pre.append((f"ap_pre_{X}", "In", "Out"))
        chain(pre)
        lim_in = f"Input {c + 1}"
        # tweeter
        tws = [pre[-1]]
        if tuning is None:
            nodes.append(f'{{ type = builtin name = tw_hp_{X} label = bq_highpass control = {{ "Freq" = 80.0 "Q" = 0.707 }} }}')
            tws.append((f"tw_hp_{X}", "In", "Out"))
        nodes.append(gain_node(f"tw_lv_{X}", tw[c])); tws.append((f"tw_lv_{X}", "In", "Out"))
        if tuning:
            for k, flt in enumerate(tuning["tweeter_eq"][c]):
                nodes.append(raw_node(f"ap_tw_{X}{k}", flt)); tws.append((f"ap_tw_{X}{k}", "In", "Out"))
        nodes.append(f'{{ type = builtin name = treb_{X} label = bq_highshelf control = {{ "Freq" = 4000.0 "Q" = 0.707 "Gain" = {treble:.1f} }} }}')
        tws.append((f"treb_{X}", "In", "Out"))
        if tuning and tuning["tweeter_delay_samples"]:
            d = tuning["tweeter_delay_samples"] / 44100
            nodes.append(f'{{ type = builtin name = tw_dl_{X} label = delay config = {{ "max-delay" = 0.01 }} control = {{ "Delay (s)" = {d:.9f} }} }}')
            tws.append((f"tw_dl_{X}", "In", "Out"))
        tws.append(("tw_lim", lim_in, None))
        chain(tws)
        # woofer
        wfs = [pre[-1]]
        if tuning is None:
            nodes.append(f'{{ type = builtin name = wf_hp_{X} label = bq_highpass control = {{ "Freq" = 40.0 "Q" = 0.707 }} }}')
            wfs.append((f"wf_hp_{X}", "In", "Out"))
        nodes.append(gain_node(f"wf_lv_{X}", wf[c])); wfs.append((f"wf_lv_{X}", "In", "Out"))
        if tuning:
            for k, flt in enumerate(tuning["woofer_eq"][c]):
                nodes.append(raw_node(f"ap_wf_{X}{k}", flt)); wfs.append((f"ap_wf_{X}{k}", "In", "Out"))
        nodes.append(f'{{ type = builtin name = bass_{X} label = bq_lowshelf control = {{ "Freq" = 150.0 "Q" = 0.707 "Gain" = {bass:.1f} }} }}')
        wfs.append((f"bass_{X}", "In", "Out"))
        wfs.append(("wf_lim", lim_in, None))
        chain(wfs)
    nodes.append(lim_node("tw_lim", loud))
    nodes.append(lim_node("wf_lim", loud))

    mode = "simple equaliser" if tuning is None else "Apple's tuning (macOS layout 16) + your settings"
    ind = "\n          "
    return f"""# iMac19,1 speakers: written by tools/eq.sh; change it with that script, not by hand.
# setting: {mode}: bass {bass:.1f} dB, treble {treble:.1f} dB, loudness {loud:.1f} dB
# loudness: {loud:.1f}
# graph: {graph_id(tuning)}
context.modules = [
  {{ name = libpipewire-module-filter-chain
    args = {{
      node.description = "iMac Speakers (EQ)"
      media.name       = "iMac Speakers (EQ)"
      filter.graph = {{
        nodes = [
          {ind.join(nodes)}
        ]
        links = [
          {ind.join(links)}
        ]
        inputs  = [ "inL:In" "inR:In" ]
        outputs = [ "tw_lim:Output 1" "tw_lim:Output 2" "wf_lim:Output 1" "wf_lim:Output 2" ]
      }}
      capture.props = {{
        node.name      = "{name}"
        media.class    = Audio/Sink
        audio.position = [ FL FR ]
        # WirePlumber saves and restores this output's volume; if that saved value is ever
        # lost, start at 50% (0.125 = 0.5 cubed), never at full volume.
        state.default-volume = 0.125
      }}
      playback.props = {{
        node.name         = "{name}.output"
        audio.position    = [ FL FR RL RR ]
        target.object     = "{target}"
        stream.dont-remix = true
        node.passive      = true
      }}
    }}
  }}
]
"""


def params(bass, treble, loud, tuning):
    tw, wf = levels(bass, treble, tuning)
    v = []
    for c, X in ((0, "L"), (1, "R")):
        v += [f'"treb_{X}:Gain" {treble:.1f}', f'"tw_lv_{X}:Gain" {tw[c]:.2f}',
              f'"bass_{X}:Gain" {bass:.1f}', f'"wf_lv_{X}:Gain" {wf[c]:.2f}']
    v += [f'"tw_lim:Input gain (dB)" {loud:.1f}', f'"wf_lim:Input gain (dB)" {loud:.1f}']
    return "{ params = [ " + " ".join(v) + " ] }"


def main(a):
    if len(a) == 3 and a[0] == "import":
        return import_layout(a[1], a[2])
    if a and a[0] in ("conf", "params", "graph"):
        tuning = None
        n = {"conf": 6, "params": 4, "graph": 1}[a[0]]
        if len(a) == n + 1:
            tuning = json.load(open(a[n]))
        elif len(a) != n:
            sys.exit(__doc__)
        if a[0] == "graph":
            return print(graph_id(tuning))
        b, t, l = (float(x) for x in a[1:4])
        if a[0] == "conf":
            return print(conf(b, t, l, a[4], a[5], tuning), end="")
        return print(params(b, t, l, tuning))
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
