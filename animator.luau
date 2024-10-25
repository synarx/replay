local Animator = {SILENCE_FORMAT_VERSION_WARNINGS = false} do
	local FORMAT_VERSION = 2

	local RunService = game:GetService("RunService")
	local TweenService = game:GetService("TweenService")

	local dir, style = Enum.EasingDirection:GetEnumItems(), Enum.EasingStyle:GetEnumItems()

	local function read_i24(b, o)
		local v = buffer.readu8(b, o) + buffer.readu8(b, o + 1) * 256 + buffer.readu8(b, o + 2) * 65536
		return v >= 8388608 and (v - 16777216) or v
	end

	local function clamp_angle(a)
		return (a / 4095) * (math.pi * 2)
	end

	local precision = 1e4
	local function read_cframe(b, o)
		return CFrame.new(
			read_i24(b, o) / precision, 
			read_i24(b, o + 3) / precision,
			read_i24(b, o + 6) / precision
		) * CFrame.Angles(
			clamp_angle(buffer.readu16(b, o + 9)), 
			clamp_angle(buffer.readu16(b, o + 11)), 
			clamp_angle(buffer.readu16(b, o + 13))
		)
	end

	local function decode(b)
		local keyframes, rig = {}, {}
		local format_version, kf_count, looping, priority, joint_count = buffer.readu8(b, 0), buffer.readu16(b, 1), buffer.readu8(b, 3), buffer.readu8(b, 4), buffer.readu8(b, 5)

		if format_version ~= FORMAT_VERSION and not Animator.SILENCE_FORMAT_VERSION_WARNINGS then
			error(`incompatiable format version - it will probably not work\n\ncurrent format version: {FORMAT_VERSION}\nanimation format version: {format_version}\n\nyou can stop seeing this message by setting Animator.SILENCE_FORMAT_VERSION_WARNINGS to true, reverting to an older animator or updating your animation to the newer encoder.`)
		end

		local offset = 6

		for i = 1, joint_count do
			local len = buffer.readu8(b, offset)
			rig[i] = buffer.readstring(b, offset + 1, len)
			offset += len + 1
		end

		for _ = 1, kf_count do
			local ts, marker_count = buffer.readf32(b, offset), buffer.readu8(b, offset + 4)
			offset += 5

			local markers = {}

			for _ = 1, marker_count do
				local marker_name_length = buffer.readu8(b, offset)
				local marker_name = buffer.readstring(b, offset + 1, marker_name_length)

				local value_length = buffer.readu8(b, offset + 1 + marker_name_length)
				local value = buffer.readstring(b, offset + 2 + marker_name_length, value_length)

				table.insert(markers, {value = value, name = marker_name})

				offset += 2 + marker_name_length + value_length
			end

			local pose_count = buffer.readu8(b, offset)

			offset += 1

			local kf = {poses = {}, markers = markers, timestamp = ts}

			for _ = 1, pose_count do
				local rig_idx, weight, ease = buffer.readu8(b, offset), buffer.readu8(b, offset + 1), buffer.readu8(b, offset + 2)
				local ease = buffer.readu8(b, offset + 2)
				local ease_dir, ease_style = bit32.rshift(bit32.band(ease, 0xF0), 4), bit32.band(ease, 0x0F)

				kf.poses[rig[rig_idx]] = {
					name = rig[rig_idx],
					weight = weight,
					easing_direction = dir[ease_dir],
					easing_style = style[ease_style],
					cframe = read_cframe(b, offset + 3),
				}

				offset += 18
			end

			table.insert(keyframes, kf)
		end

		local length = 0

		for keyframe_idx, keyframe in ipairs(keyframes) do
			if keyframe.timestamp > length then
				length = keyframe.timestamp
			end

			for pose_idx, pose in keyframe.poses do
				local idx = keyframe_idx
				local next_keyframe
				while true do
					idx += 1
					next_keyframe = keyframes[idx]
					if not next_keyframe then break end
					if next_keyframe.poses[pose_idx] then
						pose.next_keyframe = idx
						break
					end
				end
			end
		end

		return {keyframes = keyframes, looped = looping == 1, length = length, priority = Enum.AnimationPriority:GetEnumItems()[priority]}
	end

	local function base64decode(base64)
		return game:GetService("HttpService"):JSONDecode(`\{"m":null, "t":"buffer", "{base64:sub(1, 5) == "KLUv/" and "zbase64" or "base64"}":"{base64}"\}`)
	end

	local freeRunnerThread = nil

	local function acquireRunnerThreadAndCallEventHandler(fn, ...)
		local acquiredRunnerThread = freeRunnerThread
		freeRunnerThread = nil
		fn(...)
		freeRunnerThread = acquiredRunnerThread
	end

	local function runEventHandlerInFreeThread()
		while true do
			acquireRunnerThreadAndCallEventHandler(coroutine.yield())
		end
	end

	local Connection = {}
	Connection.__index = Connection

	function Connection.new(signal, fn)
		return setmetatable({
			_connected = true,
			_signal = signal,
			_fn = fn,
			_next = false,
		}, Connection)
	end

	function Connection:Disconnect()
		self._connected = false
		if self._signal._handlerListHead == self then
			self._signal._handlerListHead = self._next
		else
			local prev = self._signal._handlerListHead
			while prev and prev._next ~= self do
				prev = prev._next
			end
			if prev then
				prev._next = self._next
			end
		end
	end

	local Signal = {}
	Signal.__index = Signal

	function Signal.new()
		return setmetatable({
			_handlerListHead = false,
		}, Signal)
	end

	function Signal:Connect(fn)
		local connection = Connection.new(self, fn)
		if self._handlerListHead then
			connection._next = self._handlerListHead
			self._handlerListHead = connection
		else
			self._handlerListHead = connection
		end
		return connection
	end

	function Signal:DisconnectAll()
		self._handlerListHead = false
	end

	function Signal:Fire(...)
		local item = self._handlerListHead
		while item do
			if item._connected then
				if not freeRunnerThread then
					freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
					coroutine.resume(freeRunnerThread)
				end
				task.spawn(freeRunnerThread, item._fn, ...)
			end
			item = item._next
		end
	end

	function Signal:Wait()
		local waitingCoroutine = coroutine.running()
		local cn
		cn = self:Connect(function(...)
			cn:Disconnect()
			task.spawn(waitingCoroutine, ...)
		end)
		return coroutine.yield()
	end

	function Signal:Once(fn)
		local cn
		cn = self:Connect(function(...)
			if cn._connected then
				cn:Disconnect()
			end
			fn(...)
		end)
		return cn
	end

	local AnimationTrack = {}
	AnimationTrack.__index = AnimationTrack

	local DEFAULT_FADE_TIME = 0.1
	local DEFAULT_WEIGHT = 1

	function AnimationTrack.new(animation)
		local self = setmetatable({}, AnimationTrack)
		self._joints = {}
		self._animation = animation
		self._fade_time = DEFAULT_FADE_TIME
		self._last_weight_target = 0
		self._fade_time_tick = 0
		self._last_weight_current = 0
		self._did_ended = false
		self._last_keyframe_idx = 1
		self._original_cframes = {}

		self._marker_events = {}

		self.DidLoop = Signal.new()
		self.Ended = Signal.new()
		self.Stopped = Signal.new()

		self.TimePosition = 0
		self.Priority = animation.priority or Enum.AnimationPriority.Core
		self.WeightCurrent = 0
		self.WeightTarget = 0
		self.Speed = 1
		self.Looped = animation.looped
		self.Length = animation.length
		if animation.loaded == false then
			task.spawn(function()
				repeat task.wait() until animation.loaded
				self.Looped = animation.looped
				self.Priority = animation.priority or Enum.AnimationPriority.Core
				self.Length = animation.length
			end)
		end
		self.IsPlaying = false

		return self
	end

	function AnimationTrack:GetMarkerReachedSignal(name)
		local event = Signal.new()
		self._marker_events[name] = event
		return event
	end

	function AnimationTrack:AdjustSpeed(speed)
		self.Speed = speed
	end

	function AnimationTrack:AdjustWeight(weight, fadeTime)
		self.WeightTarget = weight or DEFAULT_WEIGHT
		self._fade_time = fadeTime or DEFAULT_FADE_TIME
	end

	function AnimationTrack:Play(fadeTime, weight, speed)
		self.Speed = speed or 1
		self._fade_time = fadeTime or DEFAULT_FADE_TIME
		self.WeightTarget = weight or DEFAULT_WEIGHT
		self.WeightCurrent = 0
		self._last_weight_target = 0
		self.IsPlaying = true
		self._did_ended = false
		self.TimePosition = 0
		self._original_cframes = {}
	end

	function AnimationTrack:Stop(fadeTime)
		self.WeightTarget = 0
		self._fade_time = fadeTime or DEFAULT_FADE_TIME
		self.IsPlaying = false
		self.Stopped:Fire()
	end

	function AnimationTrack:_update_weight(dt)
		if self._last_weight_target ~= self.WeightTarget then
			self._fade_time_tick = 0
			self._last_weight_current = self.WeightCurrent
		else
			self._fade_time_tick += dt / self._fade_time
			self.WeightCurrent = self._last_weight_current + (self.WeightTarget - self._last_weight_current) * math.clamp(self._fade_time_tick, 0, 1)
		end
		self._last_weight_target = self.WeightTarget
	end

	function AnimationTrack:_update(dt)
		if self.WeightCurrent == 0 and not self.IsPlaying then
			if not self._did_ended then
				self._did_ended = true
				self.Ended:Fire()
			end
		end

		if self.IsPlaying then
			self.TimePosition += dt * self.Speed
			if self.TimePosition < 0 then
				if self.Looped then
					self.TimePosition += self.Length
					self.DidLoop:Fire()
				else
					self:Stop()
				end
			elseif self.TimePosition > self.Length then
				if self.Looped then
					self.TimePosition -= self.Length
					self.DidLoop:Fire()
				else
					self:Stop()
				end
			end
		end

		local keyframes = self._animation.keyframes

		local keyframe_idx = 1
		local current_keyframe = keyframes[keyframe_idx]

		for i = 1, #keyframes do
			if keyframes[i].timestamp > self.TimePosition then
				break
			end
			current_keyframe = keyframes[i]
			keyframe_idx = i
		end

		local keyframe_timepos = self.TimePosition - current_keyframe.timestamp

		local transforms = {}

		for name, joint in self._joints do
			local active_keyframe = current_keyframe
			local pose = active_keyframe.poses[name]

			if not pose then
				local offset = 1
				while true do
					active_keyframe = keyframes[keyframe_idx - offset]
					if not active_keyframe or active_keyframe.poses[name] then
						break
					end
					offset += 1
				end
				pose = active_keyframe and active_keyframe.poses[name]
			end

			if pose then
				local next_keyframe = pose.next_keyframe and keyframes[pose.next_keyframe]
				if next_keyframe then
					local next_pose = next_keyframe.poses[name]
					local alpha = TweenService:GetValue((self.TimePosition - active_keyframe.timestamp) / (next_keyframe.timestamp - active_keyframe.timestamp), pose.easing_style, pose.easing_direction)
					transforms[joint] = pose.cframe:Lerp(next_pose.cframe, math.clamp(alpha, 0, 1))
				else
					transforms[joint] = pose.cframe
				end
			end
		end

		for name, joint in self._joints do
			local original_cframe = self._original_cframes[joint]
			if not original_cframe then
				local joint_transform = CFrame.identity
				local stored = joint:GetAttribute("_replay_stored_cframe")
				if stored then
					joint_transform = joint.C0:ToObjectSpace(stored)
				else
					if joint:IsA("Motor6D") or joint:IsA("Bone") then
						joint_transform = joint.Transform
					else
						joint_transform = joint.C0
					end
				end
				original_cframe = joint_transform
				self._original_cframes[joint] = original_cframe
			end
			local cframe = transforms[joint] or CFrame.identity
			transforms[joint] = original_cframe:Lerp(cframe, math.clamp(self.WeightCurrent, 0, 1))
		end

		if keyframe_idx ~= self._last_keyframe_idx then
			for _, marker in current_keyframe.markers do
				local event = self._marker_events[marker.name]
				if event then
					event:Fire(marker.value)
				end
			end
		end

		self._last_keyframe_idx = keyframe_idx

		return transforms
	end

	Animator.__index = Animator

	local animator_cache = {}
	function Animator.new(rig, raw_cframe)
		if animator_cache[rig] then
			return animator_cache[rig]
		end

		local self = setmetatable({}, Animator)
		self._tracks = {}
		self._joints = {}
		self._joint_updater = function(joint, transform)
			joint.Transform = transform
		end

		self.AnimationPlayed = Signal.new()
		self.AnimationStopped = Signal.new()
		self.Destroying = Signal.new()

		rig.Destroying:Once(function()
			self:Destroy()
		end)

		local function add_joint(joint)
			local is_bone = joint:IsA("Bone")
			local is_joint = (joint:IsA("Motor6D") and joint.Enabled)
			if is_joint or is_bone then
				local joint_name = (is_bone and joint.Name or is_joint and joint.Part1.Name)

				local current_joint = self._joints[joint_name]

				if not current_joint then
					self._joints[joint_name] = joint
				else
					if joint:IsDescendantOf(current_joint) then
						return
					elseif current_joint:IsDescendantOf(joint) then
						self._joints[joint_name] = joint
					end
				end

				joint:GetPropertyChangedSignal("Parent"):Connect(function()
					if not joint:IsDescendantOf(rig) then
						self._joints[joint_name] = nil
					else
						local current_joint = self._joints[joint_name]
						if joint:IsDescendantOf(current_joint) then
							return
						elseif current_joint:IsDescendantOf(joint) then
							self._joints[joint_name] = joint
						end
					end
				end)
			end
		end

		for _, joint in rig:GetDescendants() do
			add_joint(joint)
		end

		rig.DescendantAdded:Connect(add_joint)

		if (RunService:IsServer() and raw_cframe ~= false) or raw_cframe then
			local ATTRIBUTE_NAME = "_replay_stored_cframe"
			self._joint_updater = function(joint, transform)
				local prop = (joint.ClassName == "Bone" and "CFrame" or "C0")
				if not joint:GetAttribute(ATTRIBUTE_NAME) then
					joint:SetAttribute(ATTRIBUTE_NAME, joint[prop])
				end
				joint[prop] = joint:GetAttribute(ATTRIBUTE_NAME) * transform
			end
		end
		
		local maxPriorities = 7
		local function calcPriority(current)
			local priority = 0
			if current == Enum.AnimationPriority.Action4 then
				priority = maxPriorities
			elseif current == Enum.AnimationPriority.Action3 then
				priority = maxPriorities - 1
			elseif current == Enum.AnimationPriority.Action2 then
				priority = maxPriorities - 2
			elseif current == Enum.AnimationPriority.Action then
				priority = maxPriorities - 3
			elseif current == Enum.AnimationPriority.Movement then
				priority = maxPriorities - 4
			elseif current == Enum.AnimationPriority.Idle then
				priority = maxPriorities - 5
			elseif current == Enum.AnimationPriority.Core then
				priority = maxPriorities - 6
			end
			return priority
		end

		local last_active_track
		self._loop = RunService.Heartbeat:Connect(function(dt)
			local highest_prio = Enum.AnimationPriority.Core.Value

			local playing = {}
			for _, track in self._tracks do
				track:_update_weight(dt)

				if not track.IsPlaying then continue end

				table.insert(playing, track)
				
				local prio = calcPriority(track.Priority)
				if prio < highest_prio then
					highest_prio = prio
				end
				track._joints = self._joints
			end

			if #playing == 0 and last_active_track then
				highest_prio = calcPriority(last_active_track.Priority)
				table.insert(playing, last_active_track)
			end

			local active_tracks, active_transforms = {}, {}
			local weight_total = 0
			for _, track in playing do
				if calcPriority(track.Priority) == highest_prio then
					local transforms = track:_update(dt)
					table.insert(active_tracks, track)
					table.insert(active_transforms, transforms)
					weight_total += track.WeightCurrent
				end
			end

			local final_transform
			for idx, track in active_tracks do
				final_transform = active_transforms[idx]
				local last_track = active_tracks[idx - 1]
				if last_track then
					local last_transform = active_transforms[idx - 1]
					for idx, cf in final_transform do
						if not last_transform[idx] then continue end

						local alpha = math.clamp(track.WeightCurrent / weight_total, 0, 1)
						if weight_total == 0 then
							alpha = 0
						end
						final_transform[idx] = last_transform[idx]:Lerp(cf, alpha)
					end
				end
				last_active_track = track
			end

			if final_transform then 
				for joint, cf in final_transform do
					self._joint_updater(joint, cf)
				end
			end
		end)

		animator_cache[rig] = self

		return self
	end

	function Animator:SetJointUpdater(callback)
		self._joint_updater = callback
	end

	function Animator:Destroy()
		self.Destroying:Fire()
		self._tracks = {}
		self._joints = {}
		self._loop:Disconnect()
	end

	function Animator:LoadAnimation(animation)
		local data
		if typeof(animation) == "table" or typeof(animation) == "string" then
			data = animation
		elseif typeof(animation) == "Instance" and animation:IsA("StringValue") then
			data = animation.Value
		elseif typeof(animation) == "Instance" and animation:GetAttribute("replay_data") then
			data = animation:GetAttribute("replay_data")
		else
			error("animation must be a StringValue, table or string with valid replay3 animation data")
		end

		if typeof(animation) ~= "table" then
			data = decode(base64decode(data))
		end

		local track = AnimationTrack.new(data)
		track._joints = self._joints

		local track_idx = #self._tracks + 1
		table.insert(self._tracks, track)

		local play = track.Play
		function track.Play(track_self, ...)
			self.AnimationPlayed:Fire(track_self)
			play(track_self, ...)
		end

		local stop = track.Stop
		function track.Stop(track_self, ...)
			self.AnimationStopped:Fire(track_self)
			stop(track_self, ...)
		end

		return track
	end

	function Animator:GetPlayingAnimationTracks()
		local playing = {}
		for _, track in self._tracks do
			if track.IsPlaying then
				table.insert(playing, track)
			end
		end

		return playing
	end

	function Animator:StepAnimations(dt)
		for _, track in self:GetPlayingAnimationTracks() do
			track:_update(dt)
		end
	end
end

return Animator
