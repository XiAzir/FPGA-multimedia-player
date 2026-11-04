// 24 logarithmically spaced, half-open positive-frequency FFT bands.
// Bin 1..512, excluding DC. At 48 kHz / 1024 points: 23.4375 Hz per bin.
// The final edge is 513 so Nyquist bin 512 is included.
`define PLAYER_SPECTRUM_BAND_COUNT 24
`define PLAYER_SPECTRUM_LAST_BIN 512
