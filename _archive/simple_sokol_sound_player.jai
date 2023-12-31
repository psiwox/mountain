HEARING_PROTECTION :: 0.5;
master_vol := 0.8;

play_random_sound :: (name: string, count: int, volume: float = 1.0, pitch: float = 1.0, $random_spread := true)
{
 play_sound(resource_id_from_name(tprint("%_%", name, cast(int)random_get_within_range(0, xx count))), volume=volume, pitch=pitch, random_spread=random_spread);
}

play_sound :: (sound_id: ResourceID, volume: float = 1.0, v_left:= 1.0, v_right := 1.0, pitch:= 1.0, delay:=0.0, $random_spread := true)
{
 lock(*st.sound_mutex);
 defer unlock(*st.sound_mutex);
 
 // if it's within x amount of time of an already existing sound, don't play
 duplicate_grace_period :: 0.1;
 next_sound := sound_st.sound_instance_first;
 while next_sound
 {
 	defer next_sound = next_sound.next;
 	if next_sound.sound_id == sound_id && next_sound.samples_played / SAMPLE_RATE < duplicate_grace_period
 	{
 		return;
 	}
 }
 
 sound := get_resource(sound_id);
 
 // get the actual .wav resource
 wave : ArcResource;
 if sound.flags & .comp_sound
 {
 	if sound.play_type ==
 	{
 		case .alternate;
 		index := sound.alternate_index % sound.waves.count;
 		wave = get_resource(sound.waves[index]);
 		sound.alternate_index += 1;
 		
 		case .random;
 		wave = get_resource(sound.waves[random_int_range(0, sound.waves.count-1)]);
 	}
 }
 else
 {
 	wave = sound;
 }

 _volume := volume;
 _pitch := pitch;
 #if random_spread
 {
  volume_spread :: 0.2;
  pitch_spread :: 0.05;
  _volume += random_get_within_range(-volume_spread, volume_spread);
  _pitch += random_get_within_range(-pitch_spread, pitch_spread);
 }
 
 // create a new sound instance
 new_sound := sound_instance_create();
 new_sound.sound_id = sound.id;
 new_sound.wave_id = wave.id;
 new_sound.volume.x = _volume * v_left;
 new_sound.volume.y = _volume * v_right;
 new_sound.pitch = _pitch;
 new_sound.start_delay = delay;
 
 if LOG_VERBOSE then log("played %", wave.name);
}

SoundState :: struct
{
 buffer: [16]float;
 buffer_pos: int;
 
 sound_mutex: Mutex;
 
 sound_instance_first: *SoundInstance; // TODO - stack, queue, dll structures
 sound_instance_last: *SoundInstance;
 sound_instance_first_free: *SoundInstance;
 
 temp_counter: int;
 sound_instance_id_gen: u64;
}
sound_st: SoundState;

SoundInstance :: struct
{
 next: *SoundInstance;
 prev: *SoundInstance;
 id: u64;
 // there's a distiction here between the sound (it could be a composite sound) and the actual .wav file that's being played underneath
 sound_id: ResourceID;
 wave_id: ResourceID;
 volume: Vector2 = .{1, 1};
 pitch := 1.0;
 loop_count := 1; // -1 for infinite 
 samples_played: float64;
 start_delay: float;
}

sound_instance_create :: () -> *SoundInstance
{
 sound: *SoundInstance;
 if st.sound_instance_first_free != null
 {
  // grab from existing free list
  sound = st.sound_instance_first_free;
  stack_pop(*st.sound_instance_first_free);
 }
 else
 {
  // alloc new sound
  sound = New(SoundInstance, true, permanent_allocator);
 }
 
 st.sound_instance_id_gen += 1;
 sound.id = st.sound_instance_id_gen;
 
 dll_push_front(*st.sound_instance_first, *st.sound_instance_last, sound);
 return sound;
}

sound_instance_destroy :: (sound: *SoundInstance)
{
 dll_remove(*st.sound_instance_first, *st.sound_instance_last, sound);
 stack_push(*st.sound_instance_first_free, sound);
 next := sound.next;
 prev := sound.prev;
 <<sound = .{};
 sound.next = next;
 sound.prev = prev;
}

sound_init :: ()
{
 // todo - get rid of reliance on default allocator by creating my own hash table
 // Jai's one relies on a resizable array that can be freed or some shit
 push_allocator(context.default_allocator);
 init(*st.sound_mutex);
 
 // SOKOL SETUP
 sd: saudio_desc;
 sd.num_channels = 2;
 sd.stream_cb = audio_stream_callback;
 saudio_setup(*sd);
 assert(saudio_isvalid());
}

sound_update :: ()
{
	lock(*st.sound_mutex);
 defer unlock(*st.sound_mutex);
	
 assert(saudio_sample_rate() == SAMPLE_RATE);
 assert(saudio_channels() == 2);
 
 sound := st.sound_instance_first;
 next_sound: SoundInstance;
 while sound
 {
 	next_sound := sound.next;
 	defer sound = next_sound;
 	
 	tick_timer(*sound.start_delay, delta_t_scaled());
 }
}

audio_stream_callback :: (buffer: *float, num_frames: s32, num_channels: s32) -> void #c_call
{
 new_context: Context;
 push_context new_context {
  assert(saudio_sample_rate() == SAMPLE_RATE);
  assert(num_channels == 2);
  
  lock(*st.sound_mutex);
  defer unlock(*st.sound_mutex);
  
  for 0..num_frames-1
  {
   output: Vector2;
   sound := st.sound_instance_first;
   next_sound: SoundInstance;
   while sound
   {
    next_sound := sound.next; // grab it straight away to prevent destroy fuckery
    defer sound = next_sound;
    
    if sound.start_delay != 0 then continue;
    
    wave := get_wav(sound.wave_id);
    assert(wave.channels == 2);
    
    samp: *s16 = xx wave.sample_buffer.data;
    sample_index: int = xx floor(sound.samples_played * 2.0);
    sample_index = sample_index - sample_index % 2;
    sample_frac: float = xx frac(sound.samples_played);
    for 0..1
    {
     a := s16_to_float(samp[sample_index]);
     b := s16_to_float(samp[sample_index+2]);
     // this is kinda sketch, but it was overruning the buffer without it. Probs just me having dodgey math... - randy
     has_next_sample: bool = sample_index + 2 < wave.sample_buffer.count / 2;
     value: float = ifx has_next_sample then lerp(a, b, sample_frac) else a;
     
     output.component[it] += master_vol * value * sound.volume.component[it];
     sample_index += 1;
    }
    
    // advance sample   
    sound.samples_played += sound.pitch;
    if sound.samples_played * 2 >= xx wave.sample_buffer.count / 2.0
    {
     sound.samples_played = 0;
     if sound.loop_count > 0 then sound.loop_count -= 1;
     if sound.loop_count == 0 then sound_instance_destroy(sound);
    }
   }
   output.x = clamp(output.x, -1, 1);
   output.y = clamp(output.y, -1, 1);
   output *= HEARING_PROTECTION;
   
   buffer[it*2]   = output.x;
   buffer[it*2+1] = output.y;
  }
 }
}

sound_shutdown :: ()
{
 saudio_shutdown();
}

SAMPLE_RATE :: 44100;

#scope_file

st := *sound_st;

#import "Sokol"(.Audio);
#import "Thread";