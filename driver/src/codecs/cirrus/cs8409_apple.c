// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * cs8409_apple.c -- Apple support for the Cirrus Logic CS8409 HDA bridge
 *
 * Written for: iMac19,1 (Retina 5K, 27-inch, 2019), board Mac-AA95B1DDAB278B95
 * Values below come from this machine's SystemInfo.txt (macOS ioreg):
 *
 *   HDA controller   Intel 8086:a348 at 00:1f.3, PCI SSID 8086:7270
 *   CS8409 codec     vendor/device 0x10138409, revision 0x100100
 *   Codec SSID       0x106b1000   <- the quirk MUST match on this, not on the
 *                                    PCI SSID (which is Intel's, not Apple's)
 *   AppleHDA layout  16
 *   Pin defaults     0x90100110  speaker   (assoc 1, seq 0)   NID 0x24
 *   (set by Apple    0x90100111  speaker   (assoc 1, seq 1)   NID 0x25
 *    firmware, so    0x002b4020  headphone jack (combo)
 *    no pin override 0x00ab9030  headset mic (combo)
 *    is needed)      0x90a00100  internal mic
 *   Vendor widget    NID 0x47
 *
 *   Behind the CS8409's I2C master:
 *     CS42L83   headphone / headset codec (register-compatible with CS42L42)
 *     4x TI TAS5764L speaker amps: left/right tweeter, left/right woofer
 *       (ioreg class "AppleHDATDMAmpTAS5764L" = 4, fed over TDM)
 *
 * This file is #included from cs8409.c (just above cs8409_probe) so that it
 * can use the static CS8409 I2C helpers. It is not compiled on its own.
 *
 * Bring-up is staged. Each stage logs to the kernel log with the prefix
 * "apple:" (read it with:  journalctl -k -b | grep apple: ).
 *
 *   Stage 1  bind, name the codec "CS8409/CS42L83"          always
 *   Stage 2  dump CS8409 vendor coefficients (read-only)    apple_dump=1
 *   Stage 3  bring up the CS8409 I2C master                 apple_i2c=1
 *   Stage 4  read chip IDs over I2C (read-only)             apple_probe=1
 *   Stage 5  scan the whole I2C bus (read-only, first init)  apple_scan=1
 *   Stage 5b find the CS42L83 reset GPIO (first init)         apple_gpio_probe=1
 *   Stage 5c dump CS42L83 + amp registers (first init)       apple_regdump=1
 *            then keep it released                    apple_cs42l83_reset_gpio=N
 *   Stage 6  CS8409 ASP/TDM/PLL config   apple_hw_cfg[]          measured
 *   Stage 7  CS42L83 init                apple_cs42l83_init[]    TODO
 *   Stage 8  amp reset + amp init        apple_tas5764_*[]       measured
 *   Stream   speaker start/stop around playback   apple_spk_hook=1
 *
 * Stages 1-5 never write to the amplifiers, so they are safe to run before
 * the TODO tables are filled in. Stages 6-8 do nothing while their tables
 * are empty.
 *
 * Every init (boot, resume, and runtime power-save wake-ups) re-runs stages
 * 3 and 6-8, so the amps are reprogrammed after suspend.
 */

/* ------------------------------------------------------------------------ */
/* Module parameters: set them in /etc/modprobe.d/cs8409-apple.conf as     */
/*   options snd_hda_codec_cs8409 apple_scan=1                              */
/* ------------------------------------------------------------------------ */

static bool apple_dump;
module_param(apple_dump, bool, 0644);
MODULE_PARM_DESC(apple_dump, "Apple: dump CS8409 vendor coefficients once at first init (read-only)");

static bool apple_i2c = true;
module_param(apple_i2c, bool, 0644);
MODULE_PARM_DESC(apple_i2c, "Apple: bring up the CS8409 I2C master");

static bool apple_probe = true;
module_param(apple_probe, bool, 0644);
MODULE_PARM_DESC(apple_probe, "Apple: read CS42L83 and amp IDs over I2C (read-only)");

static bool apple_scan;
module_param(apple_scan, bool, 0644);
MODULE_PARM_DESC(apple_scan, "Apple: scan I2C addresses 0x08-0x77 at first init (read-only)");

static uint apple_cs42l83_addr = 0x48;
module_param(apple_cs42l83_addr, uint, 0644);
MODULE_PARM_DESC(apple_cs42l83_addr, "Apple: CS42L83 7-bit I2C address (default 0x48, unverified)");

static uint apple_amp_addr = 0x6c;
module_param(apple_amp_addr, uint, 0644);
MODULE_PARM_DESC(apple_amp_addr, "Apple: first TAS5764L 7-bit I2C address; the four amps are at +0..+3");

static int apple_amp_reset_gpio = -1;
module_param(apple_amp_reset_gpio, int, 0644);
MODULE_PARM_DESC(apple_amp_reset_gpio, "Apple: CS8409 GPIO that resets the amps (-1 = unknown, skip reset)");

static int apple_cs42l83_reset_gpio = 1;	/* measured on iMac19,1 */
module_param(apple_cs42l83_reset_gpio, int, 0644);
MODULE_PARM_DESC(apple_cs42l83_reset_gpio, "Apple: CS8409 GPIO holding the CS42L83 in reset; driven high at init (iMac19,1: 1; -1 = none)");

static bool apple_regdump;
module_param(apple_regdump, bool, 0644);
MODULE_PARM_DESC(apple_regdump, "Apple: dump CS42L83 and TAS5764L registers once at first init (read-only)");

static uint apple_amp_volume = 0xcf;
module_param(apple_amp_volume, uint, 0644);
MODULE_PARM_DESC(apple_amp_volume, "Apple: TAS5764L volume, reg 0x04 (0xcf = 0 dB as macOS uses, 0.5 dB per step)");

static bool apple_spk_hook = true;
module_param(apple_spk_hook, bool, 0644);
MODULE_PARM_DESC(apple_spk_hook, "Apple: run the speaker start/stop sequence around playback streams");

/* Behaviour switches for the speaker start sequence; all read at every
 * stream start, so they can be changed live through
 * /sys/module/snd_hda_codec_cs8409/parameters/ without a reboot. */
static int apple_spk_order = 1;
module_param(apple_spk_order, int, 0644);
MODULE_PARM_DESC(apple_spk_order, "Apple: 0 = slots, sync, then amps on; 1 = macOS order: each pair's slots then amps on, sync last");

static bool apple_afg_cycle = true;
module_param(apple_afg_cycle, bool, 0644);
MODULE_PARM_DESC(apple_afg_cycle, "Apple: power the audio function D3 -> D0 at stream start and re-program the converters, as macOS does");

static bool apple_hp_off = true;
module_param(apple_hp_off, bool, 0644);
MODULE_PARM_DESC(apple_hp_off, "Apple: keep the speaker stream off the headphone converter (node 0x0a) and pin 0x2c");

static bool apple_gpio_inputs = true;
module_param(apple_gpio_inputs, bool, 0644);
MODULE_PARM_DESC(apple_gpio_inputs, "Apple: enable GPIO 0, 2 and 3 as inputs, as the macOS-derived driver does");

static int apple_dev_cfg2 = -1;
module_param(apple_dev_cfg2, int, 0644);
MODULE_PARM_DESC(apple_dev_cfg2, "Apple: value written to CS8409 DEV_CFG2 (ASP enables) at every init; -1 = leave as firmware left it (0x0000)");

static bool apple_gpio_probe;
module_param(apple_gpio_probe, bool, 0644);
MODULE_PARM_DESC(apple_gpio_probe, "Apple: at first init, raise each unused GPIO briefly and report new I2C devices");

/* ------------------------------------------------------------------------ */
/* Stage 3: CS8409 I2C master bring-up.                                     */
/* These are the CS8409's own settings, as documented in the mainline Dell  */
/* tables (cs8409_cs42l42_init_verbs / cs8409_cs42l42_hw_cfg); they set up  */
/* the bridge chip, not the speakers.                                       */
/* ------------------------------------------------------------------------ */

static const struct hda_verb apple_i2c_verbs[] = {
	{ CS8409_PIN_VENDOR_WIDGET, AC_VERB_SET_PROC_STATE, 0x0001 },	/* enable vendor processing */
	{ CS8409_PIN_VENDOR_WIDGET, AC_VERB_SET_COEF_INDEX, 0x0002 },	/* GPIO 6,7 ... */
	{ CS8409_PIN_VENDOR_WIDGET, AC_VERB_SET_PROC_COEF,  0x0080 },	/* ... = I2C SCL/SDA */
	{ CS8409_PIN_VENDOR_WIDGET, AC_VERB_SET_COEF_INDEX, 0x005b },	/* I2C bus speed ... */
	{ CS8409_PIN_VENDOR_WIDGET, AC_VERB_SET_PROC_COEF,  0x0200 },	/* ... 100 kHz */
	{} /* terminator */
};

/* DEV_CFG3 "+GPIO_I2C" bit, inferred from the Dell table comment (0x0a80). */
#define APPLE_DEV_CFG3_GPIO_I2C		0x0080

/* ------------------------------------------------------------------------ */
/* Stage 6: CS8409 vendor coefficients for the Apple wiring.  TODO          */
/*                                                                          */
/* Format, one per line:                                                    */
/*   { CS8409_PIN_VENDOR_WIDGET, <coef index>, <value> },                   */
/* Coef index names are in cs8409.h (CS8409_DEV_CFG1, ASP1_A_TX_CTRL1 ...). */
/* The Apple layout sends 4 channels (LT, RT, LW, RW) to the amps over a    */
/* TDM link, so ASP1/ASP2 slot sizes, positions and clocks differ from Dell.*/
/* Compare against the "apple: coef" dump: firmware may already set some.   */
/* ------------------------------------------------------------------------ */

/*
 * Idle state, as measured on this iMac19,1 under a working driver (capture
 * of 4 Nov 2026). The values originate in macOS's AppleHDATDMBusManagerCS8409
 * (setSampleRate / setupTDMPath), via the trace notes in
 * davidjo/snd_hda_macbookpro. The four ASP1 TX slot descriptors are parked
 * disabled (bit 15) and enabled by apple_spk_start() when a stream starts.
 */
static const struct cs8409_cir_param apple_hw_cfg[] = {
	{ CS8409_PIN_VENDOR_WIDGET, CS8409_DEV_CFG2,       0x0200 },	/* ports idle */
	{ CS8409_PIN_VENDOR_WIDGET, CS8409_DEV_CFG3,       0x0280 },	/* bus idle, +GPIO_I2C */
	{ CS8409_PIN_VENDOR_WIDGET, CS8409_ASP1_CLK_CTRL1, 0x8000 },
	{ CS8409_PIN_VENDOR_WIDGET, CS8409_ASP1_CLK_CTRL2, 0x08ff },	/* firmware: 083f */
	{ CS8409_PIN_VENDOR_WIDGET, CS8409_ASP1_CLK_CTRL3, 0x0001 },	/* firmware: 0000 */
	{ CS8409_PIN_VENDOR_WIDGET, ASP1_A_TX_CTRL1,       0x8800 },	/* slot 0, parked */
	{ CS8409_PIN_VENDOR_WIDGET, ASP1_A_TX_CTRL2,       0x8820 },	/* slot 1, parked */
	{ CS8409_PIN_VENDOR_WIDGET, ASP1_B_TX_CTRL1,       0x8840 },	/* slot 2, parked */
	{ CS8409_PIN_VENDOR_WIDGET, ASP1_B_TX_CTRL2,       0x8860 },	/* slot 3, parked */
	{ CS8409_PIN_VENDOR_WIDGET, ASP1_C_TX_CTRL1,       0x8000 },	/* firmware leftovers off */
	{ CS8409_PIN_VENDOR_WIDGET, ASP1_C_TX_CTRL2,       0x8000 },
	{ CS8409_PIN_VENDOR_WIDGET, ASP1_D_TX_CTRL1,       0x8000 },
	{ CS8409_PIN_VENDOR_WIDGET, ASP1_D_TX_CTRL2,       0x8000 },
	{ CS8409_PIN_VENDOR_WIDGET, CS8409_PAD_CFG_SLW_RATE_CTRL, 0x0000 },	/* firmware: ff00 */
	{} /* terminator */
};

/* ------------------------------------------------------------------------ */
/* Stage 7: CS42L83 init sequence.  TODO                                    */
/* Format: { <16-bit paged register>, <8-bit value>, <delay us> },          */
/* The CS42L83 shares the CS42L42 register map (include/sound/cs42l42.h),   */
/* so you can use those register names.                                     */
/* ------------------------------------------------------------------------ */

static const struct cs8409_i2c_param apple_cs42l83_init[] = {
	/* TODO */
};

/* ------------------------------------------------------------------------ */
/* Stage 8: TAS5764L init.  TODO                                            */
/* Format: { <8-bit register>, <8-bit value>, <delay us> },                 */
/* _common is written to all four amps, then each amp's own table (TDM slot */
/* and channel selection differ per amp).                                   */
/* ------------------------------------------------------------------------ */

/*
 * TAS5764L set-up in macOS order (same source as above), leaving the amp
 * switched off (reg 01 = fc) until a stream starts. The volume, reg 04, is
 * written separately from apple_amp_volume. Register names are the ones of
 * the related, documented TAS5760.
 */
static const struct cs8409_i2c_param apple_tas5764_common[] = {
	{ 0x02, 0x44 },		/* digital control */
	{ 0x06, 0x55 },		/* analog control: PWM rate, gain (firmware: 51) */
	{ 0x08, 0x18 },		/* fault config; clears the error flags */
	{ 0x13, 0x00 },		/* undocumented, macOS clears it */
	{ 0x02, 0x44 },
	{ 0x01, 0xfc },		/* power: amp off until playback */
};
/* reg 03 low bits pick the TDM channel; values as measured while playing */
static const struct cs8409_i2c_param apple_tas5764_lt[] = { { 0x03, 0x80 } };
static const struct cs8409_i2c_param apple_tas5764_rt[] = { { 0x03, 0x82 } };
static const struct cs8409_i2c_param apple_tas5764_lw[] = { { 0x03, 0x81 } };
static const struct cs8409_i2c_param apple_tas5764_rw[] = { { 0x03, 0x83 } };

/* ------------------------------------------------------------------------ */
/* Companion device bookkeeping                                             */
/* ------------------------------------------------------------------------ */

struct apple_amp {
	const char *name;
	const struct cs8409_i2c_param *seq;
	unsigned int num;
	struct sub_codec sc;
};

static struct apple_amp apple_amps[] = {
	{ "left tweeter",  apple_tas5764_lt, ARRAY_SIZE(apple_tas5764_lt) },
	{ "right tweeter", apple_tas5764_rt, ARRAY_SIZE(apple_tas5764_rt) },
	{ "left woofer",   apple_tas5764_lw, ARRAY_SIZE(apple_tas5764_lw) },
	{ "right woofer",  apple_tas5764_rw, ARRAY_SIZE(apple_tas5764_rw) },
};

/*
 * Deliberately NOT placed in spec->scodecs[]: the shared suspend and
 * unsolicited-event code treats every entry there as a Dell CS42L42.
 */
static struct sub_codec apple_cs42l83 = {
	.paged = 1,
	.last_page = UINT_MAX,
};

static unsigned int apple_init_count;
static unsigned int apple_xfers;	/* I2C transfers since this init began */
static ktime_t apple_t0;		/* start of this init */

static bool apple_bus_check(struct hda_codec *codec, const char *where);

static void apple_setup_subcodecs(struct hda_codec *codec)
{
	int i;

	apple_cs42l83.codec = codec;
	apple_cs42l83.addr = (apple_cs42l83_addr & 0x7f) << 1;
	apple_cs42l83.init_seq = apple_cs42l83_init;
	apple_cs42l83.init_seq_num = ARRAY_SIZE(apple_cs42l83_init);

	for (i = 0; i < ARRAY_SIZE(apple_amps); i++) {
		apple_amps[i].sc.codec = codec;
		apple_amps[i].sc.addr = ((apple_amp_addr + i) & 0x7f) << 1;
		apple_amps[i].sc.paged = 0;
	}
}

/* ------------------------------------------------------------------------ */
/* Diagnostic I2C reads. Unlike cs8409_i2c_read() these print nothing and   */
/* also return the CS8409 I2C status register, because the stock helper     */
/* treats every completed transfer as success, including a NACK.            */
/* addr8 is the shifted (8-bit) address.                                     */
/* ------------------------------------------------------------------------ */

static int apple_i2c_read_raw(struct hda_codec *codec, unsigned int addr8,
			      unsigned int reg, unsigned int *sts)
{
	struct cs8409_spec *spec = codec->spec;
	int ret;

	guard(mutex)(&spec->i2c_mux);
	apple_xfers++;
	cs8409_enable_i2c_clock(codec);
	cs8409_set_i2c_dev_addr(codec, addr8);
	cs8409_vendor_coef_set(codec, CS8409_I2C_QREAD, (reg << 8) & 0xff00);
	ret = cs8409_i2c_wait_complete(codec);
	*sts = cs8409_vendor_coef_get(codec, CS8409_I2C_STS) & 0xffff;
	if (ret < 0)
		return -EIO;
	return cs8409_vendor_coef_get(codec, CS8409_I2C_QREAD) & 0xff;
}

/* Paged (CS42L42-style) read: write the page to register 0x00, then read. */
static int apple_i2c_read_paged(struct hda_codec *codec, unsigned int addr8,
				unsigned int reg16, unsigned int *psts, unsigned int *sts)
{
	struct cs8409_spec *spec = codec->spec;

	scoped_guard(mutex, &spec->i2c_mux) {
		apple_xfers++;
		cs8409_enable_i2c_clock(codec);
		cs8409_set_i2c_dev_addr(codec, addr8);
		cs8409_vendor_coef_set(codec, CS8409_I2C_QWRITE, (reg16 >> 8) & 0xff);
		cs8409_i2c_wait_complete(codec);
		*psts = cs8409_vendor_coef_get(codec, CS8409_I2C_STS) & 0xffff;
	}
	return apple_i2c_read_raw(codec, addr8, reg16 & 0xff, sts);
}

/* ------------------------------------------------------------------------ */
/* Stages                                                                    */
/* ------------------------------------------------------------------------ */

static void apple_dump_coefs(struct hda_codec *codec)
{
	unsigned int v[8];
	int idx, i;

	codec_info(codec, "apple: coef dump of vendor widget 0x%02x (index: values)\n",
		   CS8409_PIN_VENDOR_WIDGET);
	for (idx = 0; idx <= 0x87; idx += 8) {
		for (i = 0; i < 8; i++)
			v[i] = cs8409_vendor_coef_get(codec, idx + i) & 0xffff;
		codec_info(codec, "apple: coef %02x: %04x %04x %04x %04x %04x %04x %04x %04x\n",
			   idx, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
	}
}

/* GPIO state as the firmware left it (read-only). Reset lines live here. */
static void apple_dump_gpio(struct hda_codec *codec)
{
	codec_info(codec, "apple: gpio mask=%02x dir=%02x data=%02x wake=%02x unsol=%02x\n",
		   snd_hda_codec_read(codec, CS8409_PIN_AFG, 0, AC_VERB_GET_GPIO_MASK, 0),
		   snd_hda_codec_read(codec, CS8409_PIN_AFG, 0, AC_VERB_GET_GPIO_DIRECTION, 0),
		   snd_hda_codec_read(codec, CS8409_PIN_AFG, 0, AC_VERB_GET_GPIO_DATA, 0),
		   snd_hda_codec_read(codec, CS8409_PIN_AFG, 0, AC_VERB_GET_GPIO_WAKE_MASK, 0),
		   snd_hda_codec_read(codec, CS8409_PIN_AFG, 0, AC_VERB_GET_GPIO_UNSOLICITED_RSP_MASK, 0));
}

static void apple_i2c_bringup(struct hda_codec *codec)
{
	struct cs8409_spec *spec = codec->spec;
	unsigned int cfg3;

	snd_hda_sequence_write(codec, apple_i2c_verbs);
	cfg3 = cs8409_vendor_coef_get(codec, CS8409_DEV_CFG3);
	cs8409_vendor_coef_set(codec, CS8409_DEV_CFG3, cfg3 | APPLE_DEV_CFG3_GPIO_I2C);

	/* Hardware state may be fresh after resume: drop cached I2C state. */
	spec->dev_addr = 0;
	apple_cs42l83.last_page = UINT_MAX;
}

static void apple_probe_ids(struct hda_codec *codec)
{
	unsigned int addr8 = apple_cs42l83.addr, psts, sts;
	int id[3], i, v;

	/* CS42L83: chip ID 0x42A83 in DEVID_AB/CD/E (0x1001-0x1003) */
	for (i = 0; i < 3; i++) {
		id[i] = apple_i2c_read_paged(codec, addr8, CS42L42_DEVID_AB + i, &psts, &sts);
		codec_info(codec, "apple: CS42L83 @0x%02x reg %04x: page-sts=%04x sts=%04x val=%02x\n",
			   addr8 >> 1, CS42L42_DEVID_AB + i, psts, sts, id[i] < 0 ? 0xff : id[i]);
	}
	if (id[0] >= 0 && id[1] >= 0 && id[2] >= 0)
		codec_info(codec, "apple: CS42L83 chip id 0x%05x %s\n",
			   (id[0] << 12) | (id[1] << 4) | (id[2] >> 4),
			   ((id[0] << 12) | (id[1] << 4) | (id[2] >> 4)) == CS42L83_CHIP_ID ?
			   "(CS42L83, OK)" : "(not a CS42L83 answer)");
	apple_cs42l83.last_page = UINT_MAX;

	/* Amps: register 0x00, raw value + status */
	for (i = 0; i < ARRAY_SIZE(apple_amps); i++) {
		v = apple_i2c_read_raw(codec, apple_amps[i].sc.addr, 0x00, &sts);
		codec_info(codec, "apple: amp %-13s @0x%02x: sts=%04x reg00=%02x\n",
			   apple_amps[i].name, apple_amps[i].sc.addr >> 1, sts, v < 0 ? 0xff : v);
	}
}

/*
 * CS8409 I2C status after a read, as measured on the iMac19,1:
 *   0x0038 = a device acknowledged (the amps), 0x0028 = no device (NACK).
 * So bit 4 is the ACK bit.
 */
#define APPLE_I2C_STS_ACK	0x0010

static bool apple_i2c_present(struct hda_codec *codec, unsigned int a7)
{
	unsigned int sts;

	apple_i2c_read_raw(codec, a7 << 1, 0x00, &sts);
	return sts & APPLE_I2C_STS_ACK;
}

static void apple_scan_bits(struct hda_codec *codec, unsigned long *found)
{
	unsigned int a;

	bitmap_zero(found, 128);
	for (a = 0x08; a <= 0x77; a++)
		if (apple_i2c_present(codec, a))
			__set_bit(a, found);
}

static void apple_log_bits(struct hda_codec *codec, const char *what,
			   const unsigned long *bits)
{
	char line[128];
	unsigned int a;
	int len = 0;

	for_each_set_bit(a, bits, 128)
		len += scnprintf(line + len, sizeof(line) - len, " %02x", a);
	codec_info(codec, "apple: %s:%s\n", what, len ? line : " none");
}

static void apple_scan_bus(struct hda_codec *codec)
{
	DECLARE_BITMAP(found, 128);

	apple_scan_bits(codec, found);
	apple_log_bits(codec, "I2C devices", found);
}

/* ------------------------------------------------------------------------ */
/* Register dumps (read-only), first init only.                             */
/* ------------------------------------------------------------------------ */

/*
 * Every CS42L42/CS42L83 register that mainline marks readable, minus the
 * volatile ones (status and clear-on-read interrupt registers) and the
 * EQ coefficient block: reading EQ_COEF_OUT0 (0x2407) makes the CS42L83 hold
 * the I2C bus until it is reset (seen twice on the iMac19,1). Taken from
 * cs42l42_readable_register()/cs42l42_volatile_register() in
 * sound/soc/codecs/cs42l42.c.
 */
static const u16 apple_cs42l83_dump_regs[] = {
	CS42L42_FABID, CS42L42_REVID, CS42L42_FRZ_CTL,
	CS42L42_SRC_CTL, CS42L42_MCLK_CTL, CS42L42_SFTRAMP_RATE,
	CS42L42_SLOW_START_ENABLE, CS42L42_I2C_DEBOUNCE, CS42L42_I2C_STRETCH,
	CS42L42_I2C_TIMEOUT, CS42L42_PWR_CTL1, CS42L42_PWR_CTL2,
	CS42L42_PWR_CTL3, CS42L42_RSENSE_CTL1, CS42L42_RSENSE_CTL2,
	CS42L42_OSC_SWITCH, CS42L42_RSENSE_CTL3, CS42L42_TSENSE_CTL,
	CS42L42_TSRS_INT_DISABLE, CS42L42_HSDET_CTL1, CS42L42_HSDET_CTL2,
	CS42L42_HS_SWITCH_CTL, CS42L42_HS_CLAMP_DISABLE, CS42L42_MCLK_SRC_SEL,
	CS42L42_SPDIF_CLK_CFG, CS42L42_FSYNC_PW_LOWER, CS42L42_FSYNC_PW_UPPER,
	CS42L42_FSYNC_P_LOWER, CS42L42_FSYNC_P_UPPER, CS42L42_ASP_CLK_CFG,
	CS42L42_ASP_FRM_CFG, CS42L42_FS_RATE_EN, CS42L42_IN_ASRC_CLK,
	CS42L42_OUT_ASRC_CLK, CS42L42_PLL_DIV_CFG1, CS42L42_ADC_OVFL_INT_MASK,
	CS42L42_MIXER_INT_MASK, CS42L42_SRC_INT_MASK, CS42L42_ASP_RX_INT_MASK,
	CS42L42_ASP_TX_INT_MASK, CS42L42_CODEC_INT_MASK, CS42L42_SRCPL_INT_MASK,
	CS42L42_VPMON_INT_MASK, CS42L42_PLL_LOCK_INT_MASK, CS42L42_TSRS_PLUG_INT_MASK,
	CS42L42_PLL_CTL1, CS42L42_PLL_DIV_FRAC0, CS42L42_PLL_DIV_FRAC1,
	CS42L42_PLL_DIV_FRAC2, CS42L42_PLL_DIV_INT, CS42L42_PLL_CTL3,
	CS42L42_PLL_CAL_RATIO, CS42L42_PLL_CTL4, CS42L42_LOAD_DET_EN,
	CS42L42_HSBIAS_SC_AUTOCTL, CS42L42_WAKE_CTL, CS42L42_ADC_DISABLE_MUTE,
	CS42L42_TIPSENSE_CTL, CS42L42_MISC_DET_CTL, CS42L42_MIC_DET_CTL1,
	CS42L42_MIC_DET_CTL2, CS42L42_DET_INT1_MASK, CS42L42_DET_INT2_MASK,
	CS42L42_HS_BIAS_CTL, CS42L42_ADC_CTL, CS42L42_ADC_VOLUME,
	CS42L42_ADC_WNF_HPF_CTL, CS42L42_DAC_CTL1, CS42L42_DAC_CTL2,
	CS42L42_HP_CTL, CS42L42_CLASSH_CTL, CS42L42_MIXER_CHA_VOL,
	CS42L42_MIXER_ADC_VOL, CS42L42_MIXER_CHB_VOL, 				CS42L42_SP_RX_CH_SEL,
	CS42L42_SP_RX_ISOC_CTL, CS42L42_SP_RX_FS, CS42L42_SP_TX_ISOC_CTL,
	CS42L42_SP_TX_FS, CS42L42_SPDIF_SW_CTL1, CS42L42_SRC_SDIN_FS,
	CS42L42_SRC_SDOUT_FS, CS42L42_SPDIF_CTL1, CS42L42_SPDIF_CTL2,
	CS42L42_SPDIF_CTL3, CS42L42_SPDIF_CTL4, CS42L42_ASP_TX_SZ_EN,
	CS42L42_ASP_TX_CH_EN, CS42L42_ASP_TX_CH_AP_RES, CS42L42_ASP_TX_CH1_BIT_MSB,
	CS42L42_ASP_TX_CH1_BIT_LSB, CS42L42_ASP_TX_HIZ_DLY_CFG, CS42L42_ASP_TX_CH2_BIT_MSB,
	CS42L42_ASP_TX_CH2_BIT_LSB, CS42L42_ASP_RX_DAI0_EN, CS42L42_ASP_RX_DAI0_CH1_AP_RES,
	CS42L42_ASP_RX_DAI0_CH1_BIT_MSB, CS42L42_ASP_RX_DAI0_CH1_BIT_LSB, CS42L42_ASP_RX_DAI0_CH2_AP_RES,
	CS42L42_ASP_RX_DAI0_CH2_BIT_MSB, CS42L42_ASP_RX_DAI0_CH2_BIT_LSB, CS42L42_ASP_RX_DAI0_CH3_AP_RES,
	CS42L42_ASP_RX_DAI0_CH3_BIT_MSB, CS42L42_ASP_RX_DAI0_CH3_BIT_LSB, CS42L42_ASP_RX_DAI0_CH4_AP_RES,
	CS42L42_ASP_RX_DAI0_CH4_BIT_MSB, CS42L42_ASP_RX_DAI0_CH4_BIT_LSB, CS42L42_ASP_RX_DAI1_CH1_AP_RES,
	CS42L42_ASP_RX_DAI1_CH1_BIT_MSB, CS42L42_ASP_RX_DAI1_CH1_BIT_LSB, CS42L42_ASP_RX_DAI1_CH2_AP_RES,
	CS42L42_ASP_RX_DAI1_CH2_BIT_MSB, CS42L42_ASP_RX_DAI1_CH2_BIT_LSB, CS42L42_SUB_REVID,
};

static void apple_dump_cs42l83(struct hda_codec *codec)
{
	unsigned int addr8 = apple_cs42l83.addr, psts, sts, page = UINT_MAX;
	char line[160];
	int i, len = 0, n = 0, v;

	codec_info(codec, "apple: CS42L83 register dump (page: reg=val, -- = no answer)\n");
	for (i = 0; i <= ARRAY_SIZE(apple_cs42l83_dump_regs); i++) {
		unsigned int reg = i < ARRAY_SIZE(apple_cs42l83_dump_regs) ?
				   apple_cs42l83_dump_regs[i] : UINT_MAX;

		/* flush on page change, every 12 entries, and at the end */
		if (len && ((reg >> 8) != page || n == 12)) {
			codec_info(codec, "apple: l83 p%02x:%s\n", page, line);
			len = 0;
			n = 0;
		}
		if (reg == UINT_MAX)
			break;
		page = reg >> 8;
		v = apple_i2c_read_paged(codec, addr8, reg, &psts, &sts);
		if (!(sts & APPLE_I2C_STS_ACK) && !apple_bus_check(codec, "CS42L83 dump")) {
			codec_info(codec, "apple: l83 p%02x:%s  <- stopped at reg %04x\n",
				   page, len ? line : "", reg);
			apple_cs42l83.last_page = UINT_MAX;
			return;
		}
		if (!(sts & APPLE_I2C_STS_ACK))
			len += scnprintf(line + len, sizeof(line) - len, " %02x=--", reg & 0xff);
		else
			len += scnprintf(line + len, sizeof(line) - len, " %02x=%02x", reg & 0xff, v & 0xff);
		n++;
	}
	apple_cs42l83.last_page = UINT_MAX;
}

static void apple_dump_amps(struct hda_codec *codec)
{
	static const char * const tag[] = { "LT", "RT", "LW", "RW" };
	unsigned int sts;
	char line[80];
	int i, row, c, len, v;

	codec_info(codec, "apple: TAS5764L register dump 0x00-0x7f (-- = no answer)\n");
	for (i = 0; i < ARRAY_SIZE(apple_amps); i++) {
		for (row = 0; row < 0x80; row += 16) {
			len = 0;
			for (c = 0; c < 16; c++) {
				v = apple_i2c_read_raw(codec, apple_amps[i].sc.addr, row + c, &sts);
				if (!(sts & APPLE_I2C_STS_ACK) && !apple_bus_check(codec, "amp dump")) {
					codec_info(codec, "apple: amp %s %02x:%s  <- stopped at reg %02x\n",
						   tag[i], row, len ? line : "", row + c);
					return;
				}
				if (sts & APPLE_I2C_STS_ACK)
					len += scnprintf(line + len, sizeof(line) - len, " %02x", v & 0xff);
				else
					len += scnprintf(line + len, sizeof(line) - len, " --");
			}
			codec_info(codec, "apple: amp %s %02x:%s\n", tag[i], row, line);
		}
	}
}

/* ------------------------------------------------------------------------ */
/* GPIOs. The firmware leaves GPIO4 as an output driven high (mask=dir=data */
/* =0x10). Its state is captured at first init and written back at every    */
/* init, so it is restored after suspend and never dropped by accident.     */
/* ------------------------------------------------------------------------ */

static void apple_gpio_apply(struct hda_codec *codec)
{
	struct cs8409_spec *spec = codec->spec;

	snd_hda_codec_write(codec, CS8409_PIN_AFG, 0, AC_VERB_SET_GPIO_MASK, spec->gpio_mask);
	snd_hda_codec_write(codec, CS8409_PIN_AFG, 0, AC_VERB_SET_GPIO_DIRECTION, spec->gpio_dir);
	snd_hda_codec_write(codec, CS8409_PIN_AFG, 0, AC_VERB_SET_GPIO_DATA, spec->gpio_data);
}

static void apple_gpio_init(struct hda_codec *codec)
{
	struct cs8409_spec *spec = codec->spec;

	if (apple_init_count == 1) {
		spec->gpio_mask = snd_hda_codec_read(codec, CS8409_PIN_AFG, 0, AC_VERB_GET_GPIO_MASK, 0) & 0xff;
		spec->gpio_dir  = snd_hda_codec_read(codec, CS8409_PIN_AFG, 0, AC_VERB_GET_GPIO_DIRECTION, 0) & 0xff;
		spec->gpio_data = snd_hda_codec_read(codec, CS8409_PIN_AFG, 0, AC_VERB_GET_GPIO_DATA, 0) & 0xff;
	}
	apple_gpio_apply(codec);
}

/* Drive one GPIO as an output, high or low, keeping the others as they are. */
static void apple_gpio_drive(struct hda_codec *codec, int gpio, bool high)
{
	struct cs8409_spec *spec = codec->spec;
	unsigned int bit = BIT(gpio);

	spec->gpio_mask |= bit;
	spec->gpio_dir |= bit;
	if (high)
		spec->gpio_data |= bit;
	else
		spec->gpio_data &= ~bit;
	apple_gpio_apply(codec);
}

/*
 * Find the CS42L83 reset line: for every GPIO the firmware left unused,
 * drive it high for 20 ms, scan the bus, then put it back exactly as it
 * was. Pins the firmware already drives (GPIO4) are never touched.
 */
static void apple_gpio_find_resets(struct hda_codec *codec)
{
	struct cs8409_spec *spec = codec->spec;
	unsigned int m = spec->gpio_mask, d = spec->gpio_dir, v = spec->gpio_data;
	DECLARE_BITMAP(base, 128);
	DECLARE_BITMAP(now, 128);
	DECLARE_BITMAP(diff, 128);
	char what[48];
	int n;

	apple_scan_bits(codec, base);
	apple_log_bits(codec, "gpio probe baseline", base);

	for (n = 0; n < 8; n++) {
		if (m & BIT(n))
			continue;
		apple_gpio_drive(codec, n, true);
		fsleep(20000);
		apple_scan_bits(codec, now);
		bitmap_xor(diff, now, base, 128);
		snprintf(what, sizeof(what), "gpio%d high, changed", n);
		apple_log_bits(codec, what, diff);

		spec->gpio_mask = m;
		spec->gpio_dir = d;
		spec->gpio_data = v;
		apple_gpio_apply(codec);
		fsleep(5000);
	}
}

/*
 * Is the I2C bus still alive? Uses the left tweeter, which always answers
 * on a healthy bus. If it doesn't, log the CS8409 I2C registers and try,
 * in order: restarting the I2C clock, redoing the I2C bring-up, and holding
 * the CS42L83 in reset. Whichever brings the bus back is the culprit.
 */
static bool apple_bus_check(struct hda_codec *codec, const char *where)
{
	bool back;

	if (apple_i2c_present(codec, apple_amp_addr))
		return true;

	codec_info(codec, "apple: I2C bus LOST during %s: %u transfers, %lld ms into init\n",
		   where, apple_xfers, ktime_ms_delta(ktime_get(), apple_t0));
	codec_info(codec, "apple: coef 00=%04x 59=%04x 5a=%04x 5b=%04x 5c=%04x 5d=%04x 5e=%04x\n",
		   cs8409_vendor_coef_get(codec, 0x00), cs8409_vendor_coef_get(codec, 0x59),
		   cs8409_vendor_coef_get(codec, 0x5a), cs8409_vendor_coef_get(codec, 0x5b),
		   cs8409_vendor_coef_get(codec, 0x5c), cs8409_vendor_coef_get(codec, 0x5d),
		   cs8409_vendor_coef_get(codec, 0x5e));

	cs8409_disable_i2c_clock(codec);
	back = apple_i2c_present(codec, apple_amp_addr);
	codec_info(codec, "apple: recovery 1, I2C clock restart: %s\n", back ? "bus back" : "still dead");
	if (back)
		return true;

	apple_i2c_bringup(codec);
	back = apple_i2c_present(codec, apple_amp_addr);
	codec_info(codec, "apple: recovery 2, I2C bring-up again: %s\n", back ? "bus back" : "still dead");
	if (back)
		return true;

	if (apple_cs42l83_reset_gpio >= 0 && apple_cs42l83_reset_gpio <= 7) {
		apple_gpio_drive(codec, apple_cs42l83_reset_gpio, false);
		fsleep(5000);
		back = apple_i2c_present(codec, apple_amp_addr);
		codec_info(codec, "apple: recovery 3, CS42L83 held in reset: %s\n",
			   back ? "bus back (the CS42L83 was jamming it)" : "still dead");
		apple_gpio_drive(codec, apple_cs42l83_reset_gpio, true);
		fsleep(20000);
		apple_cs42l83.last_page = UINT_MAX;
		codec_info(codec, "apple: CS42L83 released again: bus %s\n",
			   apple_i2c_present(codec, apple_amp_addr) ? "ok" : "dead");
	}
	return false;
}

static void apple_amp_reset(struct hda_codec *codec)
{
	if (apple_amp_reset_gpio < 0 || apple_amp_reset_gpio > 7)
		return;
	apple_gpio_drive(codec, apple_amp_reset_gpio, false);	/* assert reset */
	fsleep(10000);
	apple_gpio_drive(codec, apple_amp_reset_gpio, true);	/* release */
	fsleep(10000);
}

static void apple_cs42l83_release(struct hda_codec *codec)
{
	if (apple_cs42l83_reset_gpio < 0 || apple_cs42l83_reset_gpio > 7)
		return;
	apple_gpio_drive(codec, apple_cs42l83_reset_gpio, true);
	fsleep(20000);
	apple_cs42l83.last_page = UINT_MAX;
	codec_info(codec, "apple: CS42L83 reset released on gpio%d: %s at 0x%02x\n",
		   apple_cs42l83_reset_gpio,
		   apple_i2c_present(codec, apple_cs42l83_addr) ? "answering" : "still silent",
		   apple_cs42l83_addr);
}

/*
 * The amps keep the settings the firmware gave them for the startup chime.
 * The register map is 32 bytes (it repeats every 0x20) and the only
 * difference between the four amps is register 0x05 (00/10/20/30), which
 * looks like the TDM slot. Take a snapshot at first init and, at every later
 * init, report whether the amps still hold it. Read-only.
 */
#define APPLE_AMP_REGS	0x20
static u8 apple_amp_snap[4][APPLE_AMP_REGS];
static bool apple_amp_snap_ok;

static void apple_amp_snapshot(struct hda_codec *codec)
{
	unsigned int sts;
	int i, r, v, diffs;

	for (i = 0; i < ARRAY_SIZE(apple_amps); i++) {
		diffs = 0;
		for (r = 0; r < APPLE_AMP_REGS; r++) {
			v = apple_i2c_read_raw(codec, apple_amps[i].sc.addr, r, &sts);
			if (!(sts & APPLE_I2C_STS_ACK)) {
				codec_info(codec, "apple: amp %s: no answer at reg %02x\n",
					   apple_amps[i].name, r);
				return;
			}
			if (!apple_amp_snap_ok)
				apple_amp_snap[i][r] = v;
			else if (apple_amp_snap[i][r] != v) {
				codec_info(codec, "apple: amp %s reg %02x: boot %02x, now %02x\n",
					   apple_amps[i].name, r, apple_amp_snap[i][r], v);
				diffs++;
			}
		}
		if (apple_amp_snap_ok)
			codec_info(codec, "apple: amp %s vs boot snapshot: %s\n",
				   apple_amps[i].name, diffs ? "CHANGED" : "unchanged");
		else
			codec_info(codec, "apple: amp %s snapshot: %*ph\n",
				   apple_amps[i].name, 0x15, apple_amp_snap[i]);
	}
	apple_amp_snap_ok = true;
}

static void apple_hw_init(struct hda_codec *codec)
{
	const struct cs8409_cir_param *seq;
	int ncoef = 0, nl83 = 0, namp = 0, i;

	apple_init_count++;
	apple_xfers = 0;
	apple_t0 = ktime_get();

	if (apple_dump && apple_init_count == 1) {
		apple_dump_coefs(codec);
		apple_dump_gpio(codec);
	}

	apple_gpio_init(codec);

	if (apple_i2c)
		apple_i2c_bringup(codec);

	if (apple_i2c)
		apple_amp_snapshot(codec);

	/* Amps first, before the CS42L83 comes out of reset */
	if (apple_i2c && apple_regdump && apple_init_count == 1)
		apple_dump_amps(codec);

	if (apple_i2c && apple_gpio_probe && apple_init_count == 1)
		apple_gpio_find_resets(codec);

	if (apple_i2c)
		apple_cs42l83_release(codec);

	if (apple_i2c && apple_probe && apple_init_count == 1)
		apple_probe_ids(codec);

	if (apple_i2c && apple_scan && apple_init_count == 1)
		apple_scan_bus(codec);

	if (apple_i2c && apple_regdump && apple_init_count == 1)
		apple_dump_cs42l83(codec);

	if (apple_i2c)
		codec_info(codec, "apple: bus check at end of init #%u: %s (%u transfers, %lld ms)\n",
			   apple_init_count,
			   apple_bus_check(codec, "final check") ? "ok" : "LOST",
			   apple_xfers, ktime_ms_delta(ktime_get(), apple_t0));

	/* Stage 6 */
	for (seq = apple_hw_cfg; seq->nid; seq++, ncoef++)
		cs8409_vendor_coef_set(codec, seq->cir, seq->coeff);

	if (apple_dev_cfg2 >= 0) {
		cs8409_vendor_coef_set(codec, CS8409_DEV_CFG2, apple_dev_cfg2 & 0xffff);
		codec_info(codec, "apple: DEV_CFG2 set to %04x (reads back %04x)\n",
			   apple_dev_cfg2 & 0xffff, cs8409_vendor_coef_get(codec, CS8409_DEV_CFG2));
		ncoef++;
	}

	if (!apple_i2c)
		goto out;

	/* Stage 7 */
	if (apple_cs42l83.init_seq_num &&
	    !cs8409_i2c_bulk_write(&apple_cs42l83, apple_cs42l83.init_seq,
				   apple_cs42l83.init_seq_num))
		nl83 = apple_cs42l83.init_seq_num;

	/* Stage 8 */
	for (i = 0; i < ARRAY_SIZE(apple_amps); i++)
		namp += apple_amps[i].num;
	namp += ARRAY_SIZE(apple_tas5764_common);
	if (namp) {
		namp = 0;
		apple_amp_reset(codec);
		for (i = 0; i < ARRAY_SIZE(apple_amps); i++) {
			struct apple_amp *amp = &apple_amps[i];

			if (ARRAY_SIZE(apple_tas5764_common) &&
			    !cs8409_i2c_bulk_write(&amp->sc, apple_tas5764_common,
						   ARRAY_SIZE(apple_tas5764_common)))
				namp += ARRAY_SIZE(apple_tas5764_common);
			if (amp->num && !cs8409_i2c_bulk_write(&amp->sc, amp->seq, amp->num))
				namp += amp->num;
			if (!cs8409_i2c_write(&amp->sc, 0x04, apple_amp_volume & 0xff))
				namp++;
		}
	}

out:
	codec_info(codec, "apple: init #%u: %d coef, %d CS42L83, %d amp writes\n",
		   apple_init_count, ncoef, nl83, namp);
}

/* ------------------------------------------------------------------------ */
/* Hooks                                                                    */
/* ------------------------------------------------------------------------ */

static void apple_coef_update(struct hda_codec *codec, unsigned int idx,
			      unsigned int mask, unsigned int val)
{
	unsigned int old = cs8409_vendor_coef_get(codec, idx);

	cs8409_vendor_coef_set(codec, idx, (old & ~mask) | (val & mask));
}

static void apple_amps_write(struct hda_codec *codec, unsigned int reg, unsigned int val)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(apple_amps); i++)
		cs8409_i2c_write(&apple_amps[i].sc, reg, val);
}

/*
 * Stream start, after the generic parser has programmed the converters
 * (nodes 0x02/0x03). Mirrors macOS's setupTDMPath + configureTDMUR for both
 * amp pairs and its converter sync, then switches the amps on.
 */
static void apple_afg_power(struct hda_codec *codec, unsigned int state)
{
	unsigned int v;
	int i;

	snd_hda_codec_write(codec, codec->core.afg, 0, AC_VERB_SET_POWER_STATE, state);
	for (i = 0; i < 50; i++) {
		v = snd_hda_codec_read(codec, codec->core.afg, 0, AC_VERB_GET_POWER_STATE, 0);
		if (((v >> 4) & 0x0f) == state)
			break;
		fsleep(1000);
	}
}

static void apple_tdm_pair(struct hda_codec *codec, int pair)
{
	if (pair == 0) {
		/* setSampleRate (masked) + setupTDMPath for amps 1+2 */
		apple_coef_update(codec, CS8409_DEV_CFG2, 0x0380, 0x0200);
		apple_coef_update(codec, CS8409_ASP1_CLK_CTRL3, 0x0007, 0x0001);
		apple_coef_update(codec, CS8409_ASP1_CLK_CTRL2, 0x01ff, 0x00ff);
		cs8409_vendor_coef_set(codec, ASP1_A_TX_CTRL1, 0x0800);
		cs8409_vendor_coef_set(codec, ASP1_A_TX_CTRL2, 0x0820);
		cs8409_vendor_coef_set(codec, CS8409_ASP1_CLK_CTRL1, 0x8000);
		apple_coef_update(codec, CS8409_PAD_CFG_SLW_RATE_CTRL, 0x5400, 0x5400);
		cs8409_vendor_coef_set(codec, CS8409_DEV_CFG3, 0x0280);
		apple_coef_update(codec, CS8409_DEV_CFG2, 0x0020, 0x0020);
		snd_hda_codec_write(codec, 0x24, 0, AC_VERB_SET_PIN_WIDGET_CONTROL, PIN_OUT);
	} else {
		cs8409_vendor_coef_set(codec, ASP1_B_TX_CTRL1, 0x0840);
		cs8409_vendor_coef_set(codec, ASP1_B_TX_CTRL2, 0x0860);
		snd_hda_codec_write(codec, 0x25, 0, AC_VERB_SET_PIN_WIDGET_CONTROL, PIN_OUT);
	}
	/* configureTDMUR */
	cs8409_vendor_coef_set(codec, 0x6b, 0x001f);
	apple_coef_update(codec, 0x71, 0x400f, 0x400f);
	snd_hda_codec_write(codec, CS8409_PIN_VENDOR_WIDGET, 0, 0x7f0, 0x00b6);
}

static void apple_amp_pair_on(struct hda_codec *codec, int pair)
{
	/* pair 0 = slots 0+2 (LT, RT), pair 1 = slots 1+3 (LW, RW), per reg 03 */
	static const int idx[2][2] = { { 0, 1 }, { 2, 3 } };
	int k;

	for (k = 0; k < 2; k++) {
		struct sub_codec *sc = &apple_amps[idx[pair][k]].sc;

		cs8409_i2c_write(sc, 0x08, 0x18);
		cs8409_i2c_write(sc, 0x01, 0xfd);
	}
}

/* converter sync: streams off, ASP1 sync, streams back */
static void apple_conv_sync(struct hda_codec *codec)
{
	unsigned int c2, c3;

	c2 = snd_hda_codec_read(codec, CS8409_PIN_ASP1_OUT_A, 0, AC_VERB_GET_CONV, 0);
	c3 = snd_hda_codec_read(codec, CS8409_PIN_ASP1_OUT_B, 0, AC_VERB_GET_CONV, 0);
	snd_hda_codec_write(codec, CS8409_PIN_VENDOR_WIDGET, 0, AC_VERB_SET_PROC_STATE, 0x0001);
	snd_hda_codec_write(codec, CS8409_PIN_ASP1_OUT_A, 0, AC_VERB_SET_CHANNEL_STREAMID, 0);
	cs8409_vendor_coef_set(codec, ASP1_SYNC_CTRL, 0x0001);
	snd_hda_codec_write(codec, CS8409_PIN_ASP1_OUT_B, 0, AC_VERB_SET_CHANNEL_STREAMID, 0);
	cs8409_vendor_coef_set(codec, ASP1_SYNC_CTRL, 0x0003);
	snd_hda_codec_write(codec, CS8409_PIN_ASP1_OUT_A, 0, AC_VERB_SET_CHANNEL_STREAMID, c2 & 0xff);
	snd_hda_codec_write(codec, CS8409_PIN_ASP1_OUT_B, 0, AC_VERB_SET_CHANNEL_STREAMID, c3 & 0xff);
}

/*
 * Stream start, after the generic parser has programmed the converters
 * (nodes 0x02/0x03). Mirrors macOS's play sequence: setupTDMPath and
 * configureTDMUR per amp pair, amp power-on, then the converter sync.
 */
static void apple_spk_start(struct hda_codec *codec)
{
	struct cs8409_spec *spec = codec->spec;
	unsigned int f2, f3, c2, c3;

	if (apple_gpio_inputs && (spec->gpio_mask & 0x0d) != 0x0d) {
		spec->gpio_mask |= 0x0d;	/* GPIO 0, 2, 3 enabled as inputs */
		apple_gpio_apply(codec);
	}

	if (apple_hp_off) {
		snd_hda_codec_write(codec, CS8409_PIN_ASP2_OUT_A, 0, AC_VERB_SET_CHANNEL_STREAMID, 0);
		snd_hda_codec_write(codec, 0x2c, 0, AC_VERB_SET_PIN_WIDGET_CONTROL, 0);
	}

	if (apple_afg_cycle) {
		f2 = snd_hda_codec_read(codec, CS8409_PIN_ASP1_OUT_A, 0, AC_VERB_GET_STREAM_FORMAT, 0);
		f3 = snd_hda_codec_read(codec, CS8409_PIN_ASP1_OUT_B, 0, AC_VERB_GET_STREAM_FORMAT, 0);
		c2 = snd_hda_codec_read(codec, CS8409_PIN_ASP1_OUT_A, 0, AC_VERB_GET_CONV, 0);
		c3 = snd_hda_codec_read(codec, CS8409_PIN_ASP1_OUT_B, 0, AC_VERB_GET_CONV, 0);
		apple_afg_power(codec, AC_PWRST_D3);
		apple_afg_power(codec, AC_PWRST_D0);
		snd_hda_codec_write(codec, CS8409_PIN_ASP1_OUT_A, 0, AC_VERB_SET_STREAM_FORMAT, f2);
		snd_hda_codec_write(codec, CS8409_PIN_ASP1_OUT_B, 0, AC_VERB_SET_STREAM_FORMAT, f3);
		snd_hda_codec_write(codec, CS8409_PIN_ASP1_OUT_A, 0, AC_VERB_SET_CHANNEL_STREAMID, c2 & 0xff);
		snd_hda_codec_write(codec, CS8409_PIN_ASP1_OUT_B, 0, AC_VERB_SET_CHANNEL_STREAMID, c3 & 0xff);
	}

	if (apple_spk_order == 1) {
		apple_tdm_pair(codec, 0);
		apple_amp_pair_on(codec, 0);
		apple_tdm_pair(codec, 1);
		apple_amp_pair_on(codec, 1);
		apple_conv_sync(codec);
	} else {
		apple_tdm_pair(codec, 0);
		apple_tdm_pair(codec, 1);
		apple_conv_sync(codec);
		apple_amp_pair_on(codec, 0);
		apple_amp_pair_on(codec, 1);
	}

	codec_info(codec, "apple: speakers on (order %d, afg-cycle %d, hp-off %d, gpio-in %d)\n",
		   apple_spk_order, apple_afg_cycle, apple_hp_off, apple_gpio_inputs);
}

/* Stream stop: amps off, slots parked, back to the measured idle state. */
static void apple_spk_stop(struct hda_codec *codec)
{
	apple_amps_write(codec, 0x01, 0xfc);
	cs8409_vendor_coef_set(codec, ASP1_A_TX_CTRL1, 0x8800);
	cs8409_vendor_coef_set(codec, ASP1_A_TX_CTRL2, 0x8820);
	cs8409_vendor_coef_set(codec, ASP1_B_TX_CTRL1, 0x8840);
	cs8409_vendor_coef_set(codec, ASP1_B_TX_CTRL2, 0x8860);
	apple_coef_update(codec, CS8409_DEV_CFG2, 0x0020, 0x0000);
	apple_coef_update(codec, CS8409_PAD_CFG_SLW_RATE_CTRL, 0x5400, 0x0000);
	codec_dbg(codec, "apple: speakers off\n");
}

static void apple_playback_hook(struct hda_pcm_stream *hinfo, struct hda_codec *codec,
				struct snd_pcm_substream *substream, int action)
{
	if (!apple_spk_hook || !apple_i2c)
		return;

	switch (action) {
	case HDA_GEN_PCM_ACT_PREPARE:
		apple_spk_start(codec);
		break;
	case HDA_GEN_PCM_ACT_CLEANUP:
		apple_spk_stop(codec);
		break;
	default:
		break;
	}
}

static void apple_unsol_event(struct hda_codec *codec, unsigned int res)
{
	/* TODO: headphone jack detection via the CS42L83 interrupt GPIO. */
	codec_dbg(codec, "apple: unsolicited event 0x%08x ignored\n", res);
}

/* ------------------------------------------------------------------------ */
/* Fixup entry point, referenced from cs8409_fixups[] in cs8409-tables.c    */
/* ------------------------------------------------------------------------ */

void cs8409_apple_fixups(struct hda_codec *codec, const struct hda_fixup *fix, int action)
{
	struct cs8409_spec *spec = codec->spec;

	switch (action) {
	case HDA_FIXUP_ACT_PRE_PROBE:
		apple_setup_subcodecs(codec);
		spec->num_scodecs = 0;
		spec->unsol_event = apple_unsol_event;
		codec_info(codec, "apple: Apple path selected (codec SSID 0x%08x)\n",
			   codec->core.subsystem_id);
		break;
	case HDA_FIXUP_ACT_PROBE:
		spec->gen.pcm_playback_hook = apple_playback_hook;
		cs8409_enable_ur(codec, 0);
		snd_hda_codec_set_name(codec, "CS8409/CS42L83");
		break;
	case HDA_FIXUP_ACT_INIT:
		apple_hw_init(codec);
		spec->init_done = 1;
		break;
	case HDA_FIXUP_ACT_BUILD:
		spec->build_ctrl_done = 1;
		break;
	default:
		break;
	}
}
