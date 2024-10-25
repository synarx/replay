--!native
local FORMAT_VERSION = 2

local function buffer_writei24(b, offset, value)
	if value < 0 then
		value += 16777216
	end

	buffer.writeu8(b, offset, value % 256)
	buffer.writeu8(b, offset + 1, (value // 256) % 256)
	buffer.writeu8(b, offset + 2, (value // 65536) % 256)
end

-- serializes a cframe to decent quality: not precise but fine for animations
-- max value per position axis: 838.8607
-- rotation precision: 0.08789 degrees

local pi2 = math.pi * 2
local angleScaleFactor = 4095 / pi2
local positionDecimalPrecision = 1e4
local function writeCFrame(b, offset, cframe: CFrame)
	buffer_writei24(b, offset, cframe.X * positionDecimalPrecision)
	buffer_writei24(b, offset + 3, cframe.Y * positionDecimalPrecision)
	buffer_writei24(b, offset + 6, cframe.Z * positionDecimalPrecision)

	local rx, ry, rz = cframe:ToEulerAnglesXYZ()

	local rx_scaled = math.floor((rx % pi2) * angleScaleFactor + 0.5)
	local ry_scaled = math.floor((ry % pi2) * angleScaleFactor + 0.5)
	local rz_scaled = math.floor((rz % pi2) * angleScaleFactor + 0.5)

	buffer.writeu16(b, offset + 9, rx_scaled)
	buffer.writeu16(b, offset + 11, ry_scaled)
	buffer.writeu16(b, offset + 13, rz_scaled)
end

local function indexFromEnum(enum, value)
	return table.find(enum:GetEnumItems(), value) or 1
end

return function(keyframe_sequence)
	local keyframes = keyframe_sequence:GetKeyframes()
	local struct = {}
	local rig_index = {}
	local buffer_size = 0

	for _, keyframe in ipairs(keyframes) do
		local poses: {Pose} = keyframe:GetDescendants()

		local keyframe_struct = {poses = {}, markers = {}, timestamp = keyframe.Time}

		for _, marker in keyframe:GetMarkers() do
			buffer_size += 2 + #marker.Name + #marker.Value
			table.insert(keyframe_struct.markers, {value = marker.Value, name = marker.Name})
		end

		for _, pose in ipairs(poses) do
			if not pose:IsA("Pose") then continue end
			if pose.Weight == 0 then continue end

			if not table.find(rig_index, pose.Name) then
				table.insert(rig_index, pose.Name)
				buffer_size += 1 + #pose.Name
			end

			table.insert(keyframe_struct.poses, pose)

			buffer_size += 18
		end

		buffer_size += 6

		table.insert(struct, keyframe_struct)
	end

	table.sort(struct, function(a, b)
		return a.timestamp < b.timestamp
	end)

	local b = buffer.create(buffer_size + 6)
	buffer.writeu8(b, 0, FORMAT_VERSION)
	buffer.writeu16(b, 1, #struct)
	buffer.writeu8(b, 3, keyframe_sequence.Loop and 1 or 0)
	buffer.writeu8(b, 4, indexFromEnum(Enum.AnimationPriority, keyframe_sequence.Priority))
	buffer.writeu8(b, 5, #rig_index)

	local offset = 6

	for index, name in ipairs(rig_index) do
		buffer.writeu8(b, offset, #name)
		buffer.writestring(b, offset + 1, name)

		offset += 1 + #name
	end


	for _, keyframe in ipairs(struct) do
		local timestamp = keyframe.timestamp
		buffer.writef32(b, offset, timestamp)
		buffer.writeu8(b, offset + 4, #keyframe.markers)
		offset += 5

		for _, marker in keyframe.markers do
			buffer.writeu8(b, offset, #marker.name)
			buffer.writestring(b, offset + 1, marker.name)
			buffer.writeu8(b, offset + 1 + #marker.name, #marker.value)
			buffer.writestring(b, offset + 2 + #marker.name, marker.value)
			offset += 2 + #marker.name + #marker.value
		end

		buffer.writeu8(b, offset, #keyframe.poses)
		offset += 1
		for _, pose in ipairs(keyframe.poses) do
			local index = table.find(rig_index, pose.Name)
			if not index then continue end

			buffer.writeu8(b, offset, index)
			buffer.writeu8(b, offset + 1, pose.Weight)
			buffer.writeu8(b, offset + 2, bit32.bor(bit32.lshift(indexFromEnum(Enum.EasingDirection, pose.EasingDirection), 4), indexFromEnum(Enum.EasingStyle, pose.EasingStyle)))
			writeCFrame(b, offset + 3, pose.CFrame)
			offset += 1 + 1 + 1 + 15
		end
	end

	return b
end
