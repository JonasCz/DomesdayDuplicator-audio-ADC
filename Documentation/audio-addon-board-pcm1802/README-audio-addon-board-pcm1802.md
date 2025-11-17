# An experiment to add an audio ADC to the Domesday Duplicator (DdD)

An extension to the DdD to to add synced baseband audio support, with the DdD capture app writing it as a separate WAV file. Both PCM1802 (common module from china or custom board), or using the built-in adc128s102 that is already integrated on the DE0-nano board. PCM1802 has better quality, integrated ADC notably has a high noise floor at -40dB.

## Setup:

### You can use either:

**Custom board**: I designed a custom board, which has RCAs for both the PCM 1802, and the integrated adc128s102, allowing to use 4 channels at the same time if desired. Has better power regulator than PCM1802 modules (maybe lower noise), has a DIP switch for -10dB input level if needed.

Contact @Doohickey in Domesday86 discord, for around €20 + cheap shipping in europe.

![custom board photo](Documentation/audio-addon-board-pcm1802/custom_board_photo.jpg)

**PCM1802 module**:

You can also use the low cost PCM1802 module. Connect with jumper wires, diagram:

![PCM1802 module connection diagram](Documentation/audio-addon-board-pcm1802/pcm1802_wiring_diagram.jpg)

Wires between pcm1802 and DdD should be as short as possible. You don't need to solder any of the fmt/mode/osr/bypass. Make sure the 3.3v on your module is working (3.3v is present), 3.3v needs to be connected to the pdw and fsy pins on the module. Connect lin/rin/gnd on the module to your audio source.

**adc128s102**:

Can be used with just some resistors and capacitors:

Resistors: any value between 1k and 10k works. Capacitor 1-10uF works. All capacitors and resistors need to be the same.

![adc128s102](Documentation/audio-addon-board-pcm1802/adc128_wiring_diagram.jpg)

Can be used together with PCM1802 for 4 channels.

## Firmware:

You'll need to flash the firmware of the deo-nano, using the same process as for the initial flash. (firmware file in releases section). Note that there's no backward compatiblity, both the firmware and application need to be from this repository. Firmware from this repository won't work with old application either.

## Application:

Set your audio source in the application settings, then start capturing. It will write a wav file in the same location as the RF data, and show some statistics for the audio. The application is missing the logo in the UI because I couldn't get it to work, it's not intentionally removed :-)

(original readme follows)