#!/usr/bin/env python3
"""Generate EG4 EG_PHY_BRAM INIT parameters for the spectrum coefficient ROMs."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def read_mem(path: Path, depth: int, width: int) -> list[int]:
    words = [int(s, 16) for s in path.read_text(encoding="ascii").split()]
    if len(words) != depth or any(w >= (1 << width) for w in words):
        raise ValueError(f"{path}: expected {depth} words of {width} bits")
    return words


def packed_init(words: list[int], lane_width: int) -> tuple[list[int], list[int]]:
    """Return EG4 8K INIT and INITP planes in gate-level bit order."""
    data_bits = 8 if lane_width <= 9 else 16
    parity_bits = 1 if lane_width <= 9 else 2
    data_per_init = 256 // data_bits
    parity_per_init = 256 // parity_bits
    init = [0] * ((len(words) + data_per_init - 1) // data_per_init)
    initp = [0] * ((len(words) + parity_per_init - 1) // parity_per_init)
    for address, word in enumerate(words):
        if lane_width <= 9:
            data = word & 0xFF
            parity = (word >> 8) & 1
        else:
            upper_data_bits = 8 if lane_width == 18 else lane_width - 9
            data = (word & 0xFF) | (((word >> 9) & ((1 << upper_data_bits) - 1)) << 8)
            parity = ((word >> 8) & 1) | (((word >> 17) & 1) << 1 if lane_width == 18 else 0)
        init[address // data_per_init] |= data << ((address % data_per_init) * data_bits)
        initp[address // parity_per_init] |= parity << ((address % parity_per_init) * parity_bits)
    return init, initp


def hex_params(init: list[int], initp: list[int]) -> list[str]:
    lines = []
    lines.extend(f"    .INITP_{i:02X}(256'h{x:064X})" for i, x in enumerate(initp))
    lines.extend(f"    .INIT_{i:02X}(256'h{x:064X})" for i, x in enumerate(init))
    return lines


CONTROL_PARAMETERS = {
    # C11304 inferred 1024x16 Hann ROM gate configuration.
    "hann": {
        "CEAMUX": "SIG", "CEBMUX": "0", "CLKAMUX": "SIG", "CLKBMUX": "SIG",
        "CSA0": "1", "CSA1": "1", "CSA2": "1",
        "CSB0": "1", "CSB1": "1", "CSB2": "1",
        "OCEAMUX": "1", "OCEBMUX": "0", "RSTAMUX": "0", "RSTBMUX": "0",
        "WEAMUX": "0", "WEBMUX": "0",
    },
    # C11304 inferred 512x32 twiddle ROM gate configuration.  The A-side
    # clock-enable mux is tied low while the B-side CE is tied high; ST_FFT_ISSUE
    # selects both physical 9-bit slices through the top CS input.
    "twiddle": {
        "CEAMUX": "0", "CEBMUX": "1", "CLKAMUX": "SIG", "CLKBMUX": "SIG",
        "CSA0": "1", "CSA1": "1", "CSA2": "SIG",
        "CSB0": "1", "CSB1": "1", "CSB2": "SIG",
        "OCEAMUX": "1", "OCEBMUX": "1", "RSTAMUX": "0", "RSTBMUX": "0",
        "WEAMUX": "1", "WEBMUX": "0",
    },
}


def bram(instance: str, family: str, width: int, addr_width: int, addr: str, q: str,
         enable: str, init: list[int], initp: list[int], mode: str) -> str:
    controls = CONTROL_PARAMETERS[family]
    params = [
        f'    .DATA_WIDTH_A("{width}")', f'    .DATA_WIDTH_B("{width}")',
        '.READBACK("OFF")', '.REGMODE_A("NOREG")', '.REGMODE_B("NOREG")',
        '.WRITEMODE_A("NORMAL")', '.WRITEMODE_B("NORMAL")',
        '.GSR("ENABLE")', '.RESETMODE("ASYNC")',
        '.ASYNC_RESET_RELEASE("SYNC")', f'.MODE("{mode}")',
    ]
    params += [f'.{name}("{value}")' for name, value in controls.items()]
    params += ['.INIT_FILE("NONE")']
    params += hex_params(init, initp)
    addr_expr = f"{{{addr}, {13-addr_width}'b{'1'*(13-addr_width)}}}"
    if family == "hann":
        ports = [
            f"    .addra({addr_expr}), .addrb(13'b0),",
            "    .clka(clk), .clkb(clk),",
            f"    .cea({enable}), .ceb(1'b0), .ocea(1'b1), .oceb(1'b0),",
            "    .csa(3'b111), .csb(3'b111),",
            "    .wea(1'b0), .web(1'b0), .rsta(1'b0), .rstb(1'b0),",
            "    .dia(9'b0), .dib(9'b0),",
            f"    .doa({q}), .dob()",
        ]
    else:
        ports = [
            f"    .addra({addr_expr}), .addrb({addr_expr}),",
            "    .clka(clk), .clkb(clk),",
            # These CE pins are deliberately opposite constants: they match
            # CEAMUX=0 / CEBMUX=1 in the inferred PDPW8K ROM.
            "    .cea(1'b0), .ceb(1'b1), .ocea(1'b1), .oceb(1'b1),",
            f"    .csa({{{enable}, 2'b00}}), .csb({{{enable}, 2'b00}}),",
            # Preserve the inferred PDPW8K write-control muxes.  The A-side
            # operation is disabled by CEAMUX=0; port B is the enabled reader.
            "    .wea(1'b1), .web(1'b0), .rsta(1'b0), .rstb(1'b0),",
            "    .dia(9'b0), .dib(9'b0),",
            f"    .doa({q}[8:0]), .dob({q}[17:9])",
        ]
    return "\n".join([
        "  EG_PHY_BRAM #(", ",\n".join(params), f"  ) {instance} (",
        *ports, "  );",
    ])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, default=Path(__file__).parent)
    ap.add_argument("--out", type=Path, default=Path(__file__).parent / "spectrum_coeff_rom.v")
    args = ap.parse_args()
    hann = read_mem(args.source / "spectrum_hann.mem", 1024, 16)
    twiddle = read_mem(args.source / "spectrum_twiddle.mem", 512, 32)
    h0 = [w & 0x1FF for w in hann]
    h1 = [(w >> 9) & 0x7F for w in hann]
    t0 = [w & 0x3FFFF for w in twiddle]
    t1 = [(w >> 18) & 0x3FFF for w in twiddle]
    banks = [
        ("hann_low", "hann", 9, 10, "hann_addr", "hann_low_q", "hann_en", h0, "SP8K"),
        ("hann_high", "hann", 9, 10, "hann_addr", "hann_high_q", "hann_en", h1, "SP8K"),
        ("twiddle_low", "twiddle", 18, 9, "twiddle_addr", "twiddle_low_q", "twiddle_en", t0, "PDPW8K"),
        ("twiddle_high", "twiddle", 18, 9, "twiddle_addr", "twiddle_high_q", "twiddle_en", t1, "PDPW8K"),
    ]
    inst = []
    manifest = {"roms": []}
    for name, family, width, aw, addr, q, enable, words, mode in banks:
        init, initp = packed_init(words, width)
        inst.append(bram(f"u_{name}", family, width, aw, addr, q, enable, init, initp, mode))
        manifest["roms"].append({"instance": f"u_{name}", "lane_width": width, "depth": len(words),
                                 "words_nonzero": sum(v != 0 for v in words),
                                 "word_sha256_be32": hashlib.sha256(b"".join(v.to_bytes(4, "big") for v in words)).hexdigest(),
                                 "init_count": len(init), "initp_count": len(initp)})
    sim = '''`ifdef PRIVATE_ROM_BEHAVIORAL_SIM
    reg [15:0] hann_mem [0:1023];
    reg [31:0] twiddle_mem [0:511];
    reg [15:0] sim_hann_q;
    reg [31:0] sim_twiddle_q;
    assign hann_q = sim_hann_q;
    assign twiddle_q = sim_twiddle_q;
  initial begin
    $readmemh(HANN_FILE, hann_mem);
    $readmemh(TWIDDLE_FILE, twiddle_mem);
  end
  always @(posedge clk) begin
      if (hann_en) sim_hann_q <= hann_mem[hann_addr];
      if (twiddle_en) sim_twiddle_q <= twiddle_mem[twiddle_addr];
  end
`else
  wire [8:0] hann_low_q, hann_high_q;
  wire [17:0] twiddle_low_q, twiddle_high_q;
  assign hann_q = {hann_high_q[6:0], hann_low_q};
  assign twiddle_q = {twiddle_high_q[13:0], twiddle_low_q};
'''
    primitive = "\n".join(inst)
    body = '''// Generated by gen_private_spectrum_rom.py; do not edit by hand.
module spectrum_coeff_rom #(
  parameter HANN_FILE = "spectrum_hann.mem",
  parameter TWIDDLE_FILE = "spectrum_twiddle.mem"
) (
  input wire clk,
  input wire hann_en,
  input wire [9:0] hann_addr,
  output wire [15:0] hann_q,
  input wire twiddle_en,
  input wire [8:0] twiddle_addr,
  output wire [31:0] twiddle_q
);
'''+sim+primitive+'''\n`endif
endmodule
'''
    args.out.write_text(body, encoding="ascii", newline="\n")
    manifest["source_sha256"] = {
        "hann": hashlib.sha256((args.source / "spectrum_hann.mem").read_bytes()).hexdigest(),
        "twiddle": hashlib.sha256((args.source / "spectrum_twiddle.mem").read_bytes()).hexdigest(),
    }
    manifest["inferred_read_control_mapping"] = {
        "reference": "C11304 inferred EG_PHY_BRAM gate: player_spectrum/build/manual/AC201_tf_hdmi_gate.v",
        "hann": {
            "mode": "SP8K", "data_width_a_b": 9,
            "enable": "CEA=ST_WIN_REQ; CEB mux=0",
            "clock": "CLKA/CLKB=clk, CLK muxes=SIG",
            "cs_muxes": "CSA/CSB all constant 1",
            "output": "DOA=lane[8:0], DOB unused",
            "control_parameters": dict(CONTROL_PARAMETERS["hann"]),
            "port_connections": {
                "addra": "{hann_addr,3'b111}", "addrb": "13'b0",
                "cea": "hann_en", "ceb": "1'b0",
                "clka_clkb": "clk", "ocea_oceb": "1'b1/1'b0",
                "csa_csb": "3'b111/3'b111", "wea_web": "1'b0/1'b0",
                "rsta_rstb": "1'b0/1'b0", "dia_dib": "9'b0/9'b0",
                "doa_dob": "lane[8:0]/open",
            },
        },
        "twiddle": {
            "mode": "PDPW8K", "data_width_a_b": 18,
            "enable": "CEAMUX=0; CEBMUX=1; CSA2/CSB2=ST_FFT_ISSUE",
            "clock": "CLKA/CLKB=clk, CLK muxes=SIG",
            "cs_muxes": "CSA0/1 and CSB0/1=1; CSA2/CSB2=SIG",
            "write_muxes": "WEAMUX=1; WEBMUX=0; CEAMUX=0 as in inferred ROM",
            "output": "DOA=lane[8:0], DOB=lane[17:9]",
            "control_parameters": dict(CONTROL_PARAMETERS["twiddle"]),
            "port_connections": {
                "addra_addrb": "{twiddle_addr,4'b1111}",
                "cea_ceb": "1'b0/1'b1 (mux-selected constants)",
                "clka_clkb": "clk", "ocea_oceb": "1'b1/1'b1",
                "csa_csb": "{twiddle_en,2'b00}/{twiddle_en,2'b00}",
                "wea_web": "1'b1/1'b0 (WE mux selects constants)",
                "rsta_rstb": "1'b0/1'b0", "dia_dib": "9'b0/9'b0",
                "doa_dob": "lane[8:0]/lane[17:9]",
            },
        },
        "shared": {
            "oce_a_b": "1 for twiddle; Hann A=1/B=0",
            "regmode_a_b": "NOREG", "gsr": "ENABLE",
            "resetmode": "ASYNC", "async_reset_release": "SYNC",
            "reset_mux_a_b": "0", "write_mode_a_b": "NORMAL",
            "readback": "OFF", "init_file": "NONE",
        },
        "scope_note": "Configuration and INIT data mirror the inferred C11304 gate mapping; this static manifest does not prove silicon behavior.",
    }
    manifest["output"] = str(args.out.resolve())
    (args.out.parent / "spectrum_coeff_rom_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
