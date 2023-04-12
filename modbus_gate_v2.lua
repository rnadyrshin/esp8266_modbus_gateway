WIFI_SSID = "SSID точки доступа"
WIFI_PASS = "Ключ для подключения"

MODBUS_ServerPort = 502
MODBUS_ServerMode = net.TCP
RS485_BaudRate = 9600
RS485_DataBits = 8
RS485_ParityBits = uart.PARITY_NONE
RS485_StopBits = uart.STOPBITS_1
RS485_TxOn_Pin = 6

-- GPIO Init
gpio.mode(7, gpio.INPUT, gpio.PULLUP)
gpio.mode(8, gpio.OUTPUT)
gpio.write(8, 1)
gpio.mode(RS485_TxOn_Pin, gpio.OUTPUT)
gpio.write(RS485_TxOn_Pin, 0)

-- Считаем период передачи 1 байта данных через RS485
--- Биты данных и старт-бит
Bits = RS485_DataBits + 1
--- Бит чётности
if (RS485_ParityBits ~= uart.PARITY_NONE) then Bits = Bits + 1 end
--- Стоп-бит
if (RS485_StopBits == uart.STOPBITS_1) then Bits = Bits + 1
elseif (RS485_StopBits == uart.STOPBITS_1_5) then Bits = Bits + 1.5
else Bits = Bits + 2 end
ByteTransmitTimeUs = RS485_BaudRate / Bits
ByteTransmitTimeUs = 1000000 / ByteTransmitTimeUs

--  Стартуем подключение к wifi-точке
wifi.setmode(wifi.STATION)
wifi.sta.config(WIFI_SSID, WIFI_PASS)
wifi.sta.connect()

-- Глобальные переменные
local wifi_status_old = 0
local MB_uart_rx_buff = ""
local MB_tcp_rx_buff = ""
local MB_wait_rx = false
local MB_wait_rx_time = 1000
local MBtranId = 0
local MBserver = nil
local MBsock = nil


function uart_setup()
    node.output(function(str) end, 0)
    uart.alt(1)
    uart.setup(0, RS485_BaudRate, RS485_DataBits, RS485_ParityBits, RS485_StopBits, 0)
end


function process_crc(aData)
    local crc = 0xFFFF

    for i = 1, #aData do
        crc = bit.bxor(crc, string.byte(aData, i))
        for j = 0, 7 do
            if bit.band(crc, 1) > 0 then
                crc = bit.rshift(crc, 1)
                crc = bit.bxor(crc, 0xA001)
            else
                crc = bit.rshift(crc, 1)
            end
        end
    end
    return crc
end


function modbus_rtu_rx()
    if (MBsock ~= nil) then
        -- Собираем ответный пакет
        local answer = string.sub(MB_uart_rx_buff, 1, #MB_uart_rx_buff - 2)
        crc = process_crc(answer)
        
        if (string.byte(MB_uart_rx_buff, #MB_uart_rx_buff - 1) == bit.band(crc, 0xff))
        and (string.byte(MB_uart_rx_buff, #MB_uart_rx_buff) == bit.rshift(crc, 8)) then

            -- Собираем шапку MODBUS TCP пакета
            local head = ""
            head = head..string.char(bit.rshift(MBtranId, 8))
            head = head..string.char(bit.band(MBtranId, 0xff))
            head = head..string.char(0x00)
            head = head..string.char(0x00)
            head = head..string.char(bit.rshift(#answer, 8))
            head = head..string.char(bit.band(#answer, 0xff))

            answer = head..answer
                            
            MBsock:send(answer)
        end
    end
	
	tmr.unregister(5)
	modbus_tcp_frombuff()
end


function RS485_send(paket)
    gpio.write(RS485_TxOn_Pin, 1)
    uart.write(0, paket)
    tmr.delay(ByteTransmitTimeUs * #paket)
    gpio.write(RS485_TxOn_Pin, 0)

    MB_uart_rx_buff = ""
    
    uart.on("data", 1, function(data) 
        MB_uart_rx_buff = MB_uart_rx_buff..data
        if (#MB_uart_rx_buff > 256) then MB_uart_rx_buff = "" end
    
        -- [Пере]запускаем таймер ожидания очередного байта
        tmr.alarm(6, 5, tmr.ALARM_SINGLE, function() 
            modbus_rtu_rx()
        end)
    end, 0)
end


function modbus_tcp_frombuff()
	MB_wait_rx = false
	if (#MB_tcp_rx_buff > 0) then
		modbus_tcp_rx(MB_tcp_rx_buff)
		MB_tcp_rx_buff = ""
	end
end


function modbus_tcp_rx(paket)
	uart_setup()
   
	local rtu_body = string.sub(paket, 7, #paket)

	-- Запоминаем Transaction ID для отправки в ответе	
	MBtranId = (string.byte(paket, 1)*256) + string.byte(paket, 2)

	-- Считаем CRC
	crc = process_crc(rtu_body)
	rtu_body = rtu_body..string.char(bit.band(crc, 0xff))
	rtu_body = rtu_body..string.char(bit.rshift(crc, 8))

	RS485_send(rtu_body)

	MB_wait_rx = true
	tmr.alarm(5, MB_wait_rx_time, tmr.ALARM_SINGLE, modbus_tcp_frombuff)
end


tmr.alarm(0, 5000, tmr.ALARM_AUTO, function()
    print("tmr0 "..wifi_status_old.." "..wifi.sta.status())

    if wifi.sta.status() == 5 then -- подключение есть
        if wifi_status_old ~= 5 then -- Произошло подключение к Wifi, IP получен
            print(wifi.sta.getip())
            
            MBserver = net.createServer(MODBUS_ServerMode, 30)
            MBserver:listen(MODBUS_ServerPort, function(c)
                c:on("receive", function(sock, payload) 
                    MBsock = sock
                    
					if (MB_wait_rx) then	-- уже ждём ответ от слейва, запоминаем пакет в очереди
						MB_tcp_rx_buff = payload
					    print("remember")
                    else
						modbus_tcp_rx(payload)
					    print("sent")
					end
				end)
            end)
        else
            -- подключение есть и не разрывалось
        end
    else
        if (MBserver ~= nil) then
            MBserver:close()
            MBsock = nil
			tmr.unregister(5)
            MB_uart_rx_buff = ""
			MB_tcp_rx_buff = ""
			MB_wait_rx = false
        end
        wifi.sta.connect()
    end

    -- Запоминаем состояние подключения к Wifi для следующего такта таймера
    wifi_status_old = wifi.sta.status()
end)
