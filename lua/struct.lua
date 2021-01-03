local struct = {}

function struct.pack(format, ...)
    local stream = {}
    local vars = {...}
    local endianness = true

    for i = 1, format:len() do
        local opt = format:sub(i, i)

        if opt == '<' then
            endianness = true
        elseif opt == '>' then
            endianness = false
        elseif opt:find('[bBhHiIlL]') then
            local n = opt:find('[hH]') and 2 or opt:find('[iI]') and 4 or opt:find('[lL]') and 8 or 1
            local val = tonumber(table.remove(vars, 1))

            local bytes = {}
            for _ = 1, n do
                table.insert(bytes, string.char(val % (2 ^ 8)))
                val = math.floor(val / (2 ^ 8))
            end

            if not endianness then
                table.insert(stream, string.reverse(table.concat(bytes)))
            else
                table.insert(stream, table.concat(bytes))
            end
        elseif opt:find('[fd]') then
            local val = tonumber(table.remove(vars, 1))
            local sign = 0

            if val < 0 then
                sign = 1
                val = -val
            end

            local mantissa, exponent = math.frexp(val)
            if val == 0 then
                mantissa = 0
                exponent = 0
            else
                mantissa = (mantissa * 2 - 1) * math.ldexp(0.5, (opt == 'd') and 53 or 24)
                exponent = exponent + ((opt == 'd') and 1022 or 126)
            end

            local bytes = {}
            if opt == 'd' then
                val = mantissa
                for _ = 1, 6 do
                    table.insert(bytes, string.char(math.floor(val) % (2 ^ 8)))
                    val = math.floor(val / (2 ^ 8))
                end
            else
                table.insert(bytes, string.char(math.floor(mantissa) % (2 ^ 8)))
                val = math.floor(mantissa / (2 ^ 8))
                table.insert(bytes, string.char(math.floor(val) % (2 ^ 8)))
                val = math.floor(val / (2 ^ 8))
            end

            table.insert(bytes, string.char(math.floor(exponent * ((opt == 'd') and 16 or 128) + val) % (2 ^ 8)))
            val = math.floor((exponent * ((opt == 'd') and 16 or 128) + val) / (2 ^ 8))
            table.insert(bytes, string.char(math.floor(sign * 128 + val) % (2 ^ 8)))

            if not endianness then
                table.insert(stream, string.reverse(table.concat(bytes)))
            else
                table.insert(stream, table.concat(bytes))
            end
        elseif opt == 's' then
            table.insert(stream, tostring(table.remove(vars, 1)))
            table.insert(stream, string.char(0))
        elseif opt == 'c' then
            local n = format:sub(i + 1):match('%d+')
            local str = tostring(table.remove(vars, 1))
            local len = tonumber(n)
            if len <= 0 then
                len = str:len()
            end
            if len - str:len() > 0 then
                str = str .. string.rep(' ', len - str:len())
            end
            table.insert(stream, str:sub(1, len))
        end
    end

    return table.concat(stream)
end

function struct.unpack(format, stream, pos)
    local vars = {}
    local iterator = pos or 1
    local endianness = true

    for i = 1, format:len() do
        local opt = format:sub(i, i)

        if opt == '<' then
            endianness = true
        elseif opt == '>' then
            endianness = false
        elseif opt:find('[bBhHiIlL]') then
            local n = opt:find('[hH]') and 2 or opt:find('[iI]') and 4 or opt:find('[lL]') and 8 or 1
            local signed = opt:lower() == opt

            local val = 0
            for j = 1, n do
                local byte = string.byte(stream:sub(iterator, iterator))
                if endianness then
                    val = val + byte * (2 ^ ((j - 1) * 8))
                else
                    val = val + byte * (2 ^ ((n - j) * 8))
                end
                iterator = iterator + 1
            end

            if signed and val >= 2 ^ (n * 8 - 1) then
                val = val - 2 ^ (n * 8)
            end

            table.insert(vars, math.floor(val))
        elseif opt:find('[fd]') then
            local n = (opt == 'd') and 8 or 4
            local x = stream:sub(iterator, iterator + n - 1)
            iterator = iterator + n

            if not endianness then
                x = string.reverse(x)
            end

            local sign = 1
            local mantissa = string.byte(x, (opt == 'd') and 7 or 3) % ((opt == 'd') and 16 or 128)
            for j = n - 2, 1, -1 do
                mantissa = mantissa * (2 ^ 8) + string.byte(x, j)
            end

            if string.byte(x, n) > 127 then
                sign = -1
            end

            local exponent = (string.byte(x, n) % 128) * ((opt == 'd') and 16 or 2) +
                math.floor(string.byte(x, n - 1) /
                ((opt == 'd') and 16 or 128))
            if exponent == 0 then
                table.insert(vars, 0.0)
            else
                mantissa = (math.ldexp(mantissa, (opt == 'd') and -52 or -23) + 1) * sign
                table.insert(vars, math.ldexp(mantissa, exponent - ((opt == 'd') and 1023 or 127)))
            end
        elseif opt == 's' then
            local bytes = {}
            for j = iterator, stream:len() do
                if stream:sub(j,j) == string.char(0) or  stream:sub(j) == '' then
                    break
                end

                table.insert(bytes, stream:sub(j, j))
            end

            local str = table.concat(bytes)
            iterator = iterator + str:len() + 1
            table.insert(vars, str)
        elseif opt == 'c' then
            local n = format:sub(i + 1):match('%d+')
            local len = tonumber(n)
            if len <= 0 then
                len = table.remove(vars)
            end

            table.insert(vars, stream:sub(iterator, iterator + len - 1))
            iterator = iterator + len
        end
    end

    return unpack(vars)
end

return struct
