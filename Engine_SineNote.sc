// Engine_SineNote.sc
//
// This is the SuperCollider side of the norns script.
// A norns "engine" is a class that extends CroneEngine.
// The class name MUST be "Engine_" + the name you set in Lua
// with `engine.name = "SineNote"`.

Engine_SineNote : CroneEngine {

	// a control bus holding the master amplitude. every note synth reads
	// it live, so changing it affects notes that are already sounding.
	var <ampBus;

	// *new is the constructor norns calls. Just pass through to super.
	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// alloc runs once when the engine is loaded.
	// Define buses, SynthDefs and register commands here.
	alloc {

		// allocate the master-amplitude bus and give it a starting value.
		ampBus = Bus.control(context.server, 1);
		ampBus.set(1.0);

		// The actual sound: one sine oscillator shaped by an envelope,
		// then scaled by the shared master amplitude.
		//   env levels: 0 -> amp -> amp -> 0   (starts and ends silent)
		//   env times : fadeIn, sustain, fadeOut
		// doneAction: 2 frees the synth automatically when the env ends.
		SynthDef("sineNote", {
			arg freq = 440,
			    amp = 0.5,
			    fadeIn = 8,
			    sustain = 10,
			    fadeOut = 5,
			    wave = 0,     // 0 = sine, 1 = saw, 2 = pulse
			    gate = 1,     // 1 = normal; set to 0 to fast-release
			    relTime = 1.5,// seconds for the fast release
			    ampBus = 0,
			    out = 0;

			var env, rel, master, sig;

			env = EnvGen.kr(
				Env.new(
					levels: [0, amp, amp, 0],
					times:  [fadeIn, sustain, fadeOut],
					curve:  \sin            // smooth S-curve fades
				),
				doneAction: Done.freeSelf   // == 2, frees synth at the end
			);

			// a second envelope that sits at 1 while gate is held, and ramps
			// to 0 over relTime when gate is released (0). that gives us the
			// optional "fast fade-out" without clicking, and frees the synth.
			rel = EnvGen.kr(
				Env.asr(0, 1, relTime, \sin),
				gate,
				doneAction: Done.freeSelf
			);

			// read the current master amplitude from the control bus
			master = In.kr(ampBus);

			// pick the oscillator by index. Select.ar builds all three and
			// outputs the one chosen by `wave`.
			sig = Select.ar(wave, [
				SinOsc.ar(freq),
				Saw.ar(freq),
				Pulse.ar(freq)
			]);

			sig = sig * env * rel * master;

			// send the same signal to left and right
			Out.ar(out, [sig, sig]);
		}).add;

		// Make sure the SynthDef is registered before any command uses it.
		context.server.sync;

		// engine.playNote(freq, fadeIn, sustain, fadeOut, wave)
		// "fffff" = five float arguments.
		this.addCommand("playNote", "fffff", { arg msg;
			Synth.new(
				"sineNote",
				[
					\freq,    msg[1],
					\fadeIn,  msg[2],
					\sustain, msg[3],
					\fadeOut, msg[4],
					\wave,    msg[5],
					\ampBus,  ampBus.index,   // tell the synth which bus to read
					\out,     context.out_b.index
				],
				context.xg   // the engine's group in the audio graph
			);
		});

		// engine.setAmp(level) -- live master amplitude for the whole mix.
		this.addCommand("setAmp", "f", { arg msg;
			ampBus.set(msg[1]);
		});

		// engine.releaseAll(relTime) -- fast fade-out: release EVERY sounding
		// note over relTime seconds. Sets the controls on all synths in the
		// engine group at once, then each frees itself when its release ends.
		this.addCommand("releaseAll", "f", { arg msg;
			context.xg.set(\relTime, msg[1], \gate, 0);
		});
	}

	// Called when the engine is unloaded. Free the bus we allocated.
	// (Each note frees itself via doneAction.)
	free {
		ampBus.free;
	}
}
