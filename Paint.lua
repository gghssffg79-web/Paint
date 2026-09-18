local gpu = require("component").gpu
local event = require("event")
local computer = require("computer")
local fs = require("filesystem")

gpu.setResolution(40, 20)

local CANVAS_X, CANVAS_Y = 1, 1
local CANVAS_W, CANVAS_H = 30, 16
local PANEL_X = 32
local MAX_UNDO = 15

local PALETTE = {
  0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF,
  0xFFFF00, 0xFF00FF, 0x00FFFF, 0xFF8800,
  0x888888, 0x884400, 0x008800, 0x000000
}

local TOOLS = {
  {name="Pencil",  sym="*"},
  {name="Eraser",  sym="x"},
  {name="Line",    sym="/"},
  {name="Rect",    sym="[]"},
  {name="Circle",  sym="O"},
  {name="Fill",    sym="@"},
  {name="Pick",    sym="?"}
}

local canvas = {}
local curColor = 1
local curTool = 1
local brushSize = 1
local undoStack = {}
local redoStack = {}
local drawing = false
local lastX, lastY = nil, nil
local tempStart = nil

local function initCanvas()
  canvas = {}
  for y = 1, CANVAS_H do
    canvas[y] = {}
    for x = 1, CANVAS_W do
      canvas[y][x] = {color = 0, sym = " "}
    end
  end
end

local function saveState()
  local state = {}
  for y = 1, CANVAS_H do
    state[y] = {}
    for x = 1, CANVAS_W do
      state[y][x] = {color = canvas[y][x].color, sym = canvas[y][x].sym}
    end
  end
  table.insert(undoStack, state)
  if #undoStack > MAX_UNDO then table.remove(undoStack, 1) end
  redoStack = {}
end

local function undo()
  if #undoStack == 0 then return end
  local state = table.remove(undoStack)
  local cur = {}
  for y = 1, CANVAS_H do
    cur[y] = {}
    for x = 1, CANVAS_W do
      cur[y][x] = {color = canvas[y][x].color, sym = canvas[y][x].sym}
    end
  end
  table.insert(redoStack, cur)
  canvas = state
  drawCanvas()
  computer.beep(400, 0.05)
end

local function redo()
  if #redoStack == 0 then return end
  local state = table.remove(redoStack)
  local cur = {}
  for y = 1, CANVAS_H do
    cur[y] = {}
    for x = 1, CANVAS_W do
      cur[y][x] = {color = canvas[y][x].color, sym = canvas[y][x].sym}
    end
  end
  table.insert(undoStack, cur)
  canvas = state
  drawCanvas()
  computer.beep(500, 0.05)
end

local function setPixel(x, y, color, sym)
  if x < 1 or x > CANVAS_W or y < 1 or y > CANVAS_H then return end
  canvas[y][x].color = color
  canvas[y][x].sym = sym or "#"
end

local function getPixel(x, y)
  if x < 1 or x > CANVAS_W or y < 1 or y > CANVAS_H then return 0, " " end
  return canvas[y][x].color, canvas[y][x].sym
end

local function drawLine(x0, y0, x1, y1, color, sym)
  local dx = math.abs(x1 - x0)
  local dy = math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx - dy
  while true do
    setPixel(x0, y0, color, sym)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 > -dy then err = err - dy; x0 = x0 + sx end
    if e2 < dx then err = err + dx; y0 = y0 + sy end
  end
end

local function drawCircle(cx, cy, r, color, sym)
  local x, y = r, 0
  local err = 1 - r
  while x >= y do
    setPixel(cx + x, cy + y, color, sym)
    setPixel(cx + y, cy + x, color, sym)
    setPixel(cx - y, cy + x, color, sym)
    setPixel(cx - x, cy + y, color, sym)
    setPixel(cx - x, cy - y, color, sym)
    setPixel(cx - y, cy - x, color, sym)
    setPixel(cx + y, cy - x, color, sym)
    setPixel(cx + x, cy - y, color, sym)
    y = y + 1
    if err <= 0 then
      err = err + 2*y + 1
    else
      x = x - 1
      err = err + 2*(y - x) + 1
    end
  end
end

local function drawRect(x0, y0, x1, y1, color, sym)
  local minX, maxX = math.min(x0,x1), math.max(x0,x1)
  local minY, maxY = math.min(y0,y1), math.max(y0,y1)
  for x = minX, maxX do
    setPixel(x, minY, color, sym)
    setPixel(x, maxY, color, sym)
  end
  for y = minY, maxY do
    setPixel(minX, y, color, sym)
    setPixel(maxX, y, color, sym)
  end
end

local function floodFill(sx, sy, newColor)
  local targetColor = canvas[sy][sx].color
  if targetColor == newColor then return end
  local queue = {{sx, sy}}
  local visited = {}
  while #queue > 0 do
    local p = table.remove(queue, 1)
    local x, y = p[1], p[2]
    local key = x..","..y
    if not visited[key] and x >= 1 and x <= CANVAS_W and y >= 1 and y <= CANVAS_H then
      if canvas[y][x].color == targetColor then
        visited[key] = true
        setPixel(x, y, newColor, "#")
        table.insert(queue, {x+1, y})
        table.insert(queue, {x-1, y})
        table.insert(queue, {x, y+1})
        table.insert(queue, {x, y-1})
      end
    end
  end
end

local function brush(x, y, color, sym)
  local r = brushSize
  for dy = -r+1, r-1 do
    for dx = -r+1, r-1 do
      if dx*dx + dy*dy <= r*r then
        setPixel(x+dx, y+dy, color, sym)
      end
    end
  end
end

local function drawCanvas()
  for y = 1, CANVAS_H do
    for x = 1, CANVAS_W do
      local px = CANVAS_X + x - 1
      local py = CANVAS_Y + y - 1
      local cell = canvas[y][x]
      if cell.color == 0 then
        gpu.setBackground(0x111111)
      else
        gpu.setBackground(PALETTE[cell.color])
      end
      gpu.setForeground(PALETTE[cell.color])
      gpu.set(px, py, cell.sym)
    end
  end
end

local function drawPanel()
  gpu.setBackground(0x222244)
  gpu.fill(PANEL_X, 1, 9, 20, " ")
  
  gpu.setBackground(0x0066CC)
  gpu.fill(PANEL_X, 1, 9, 1, " ")
  gpu.setForeground(0xFFFFFF)
  gpu.set(PANEL_X + 1, 1, "PAINT")
  
  gpu.setForeground(0xFFFFFF)
  gpu.set(PANEL_X, 3, "Tools:")
  for i, t in ipairs(TOOLS) do
    local bg = (i == curTool) and 0x00AA00 or 0x333333
    gpu.setBackground(bg)
    gpu.fill(PANEL_X, 4 + i - 1, 9, 1, " ")
    gpu.set(PANEL_X + 1, 4 + i - 1, t.sym .. " " .. t.name)
  end
  
  local palY = 12
  gpu.setForeground(0xFFFFFF)
  gpu.setBackground(0x222244)
  gpu.set(PANEL_X, palY, "Color:")
  for i = 1, 12 do
    local row = math.floor((i-1) / 4)
    local col = (i-1) % 4
    local px = PANEL_X + col * 2
    local py = palY + 1 + row
    gpu.setBackground(PALETTE[i])
    gpu.fill(px, py, 2, 1, " ")
    if i == curColor then
      gpu.setForeground(0xFFFFFF)
      gpu.set(px, py, "#")
    end
  end
  
  local sizeY = 16
  gpu.setBackground(0x222244)
  gpu.setForeground(0xFFFFFF)
  gpu.set(PANEL_X, sizeY, "Size:" .. brushSize)
  for i = 1, 3 do
    local bg = (i == brushSize) and 0x00AA00 or 0x444444
    gpu.setBackground(bg)
    gpu.fill(PANEL_X + (i-1)*3, sizeY + 1, 2, 1, " ")
    gpu.set(PANEL_X + (i-1)*3, sizeY + 1, tostring(i))
  end
  
  local btnY = 18
  gpu.setBackground(0xFF6600)
  gpu.fill(PANEL_X, btnY, 4, 1, " ")
  gpu.set(PANEL_X, btnY, "UNDO")
  
  gpu.setBackground(0x00AA00)
  gpu.fill(PANEL_X + 5, btnY, 4, 1, " ")
  gpu.set(PANEL_X + 5, btnY, "SAVE")
  
  gpu.setBackground(0x0066CC)
  gpu.fill(PANEL_X, btnY + 1, 4, 1, " ")
  gpu.set(PANEL_X, btnY + 1, "LOAD")
  
  gpu.setBackground(0xFF0000)
  gpu.fill(PANEL_X, 20, 9, 1, " ")
  gpu.setForeground(0xFFFFFF)
  gpu.set(PANEL_X + 1, 20, "EXIT")
end

local function draw()
  drawCanvas()
  drawPanel()
end

local function getCanvasPos(x, y)
  if x < CANVAS_X or x >= CANVAS_X + CANVAS_W then return nil end
  if y < CANVAS_Y or y >= CANVAS_Y + CANVAS_H then return nil end
  return x - CANVAS_X + 1, y - CANVAS_Y + 1
end

local function handleTouch(x, y)
  if x >= PANEL_X and x <= PANEL_X + 8 and y == 20 then
    computer.beep(300, 0.2)
    os.exit()
    return
  end
  
  if x >= PANEL_X and x <= PANEL_X + 3 and y == 18 then
    undo()
    return
  end
  
  if x >= PANEL_X + 5 and x <= PANEL_X + 8 and y == 18 then
    local f = io.open("/home/picture.dat", "w")
    if f then
      f:write(CANVAS_W .. " " .. CANVAS_H .. "\n")
      for cy = 1, CANVAS_H do
        for cx = 1, CANVAS_W do
          f:write(canvas[cy][cx].color .. canvas[cy][cx].sym .. " ")
        end
        f:write("\n")
      end
      f:close()
      computer.beep(700, 0.1)
    end
    return
  end
  
  if x >= PANEL_X and x <= PANEL_X + 3 and y == 19 then
    if fs.exists("/home/picture.dat") then
      local f = io.open("/home/picture.dat", "r")
      if f then
        local header = f:read("*l")
        local w, h = header:match("(%d+) (%d+)")
        if tonumber(w) == CANVAS_W and tonumber(h) == CANVAS_H then
          for cy = 1, CANVAS_H do
            local line = f:read("*l")
            if line then
              local cx = 1
              for token in line:gmatch("(%S+)") do
                if cx <= CANVAS_W then
                  local color = tonumber(token:sub(1,1))
                  local sym = token:sub(2,2)
                  if color and sym then
                    canvas[cy][cx] = {color = color, sym = sym}
                  end
                end
                cx = cx + 1
              end
            end
          end
        end
        f:close()
        drawCanvas()
        computer.beep(600, 0.1)
      end
    end
    return
  end
  
  for i in ipairs(TOOLS) do
    if x >= PANEL_X and x <= PANEL_X + 8 and y == 4 + i - 1 then
      curTool = i
      computer.beep(500, 0.05)
      draw()
      return
    end
  end
  
  local palY = 12
  if y >= palY + 1 and y <= palY + 3 then
    local row = y - palY - 1
    local col = math.floor((x - PANEL_X) / 2)
    local idx = row * 4 + col + 1
    if idx >= 1 and idx <= 12 then
      curColor = idx
      computer.beep(600, 0.05)
      draw()
      return
    end
  end
  
  local sizeY = 16
  if y == sizeY + 1 and x >= PANEL_X and x <= PANEL_X + 8 then
    local s = math.floor((x - PANEL_X) / 3) + 1
    if s >= 1 and s <= 3 then
      brushSize = s
      computer.beep(550, 0.05)
      draw()
      return
    end
  end
  
  local cx, cy = getCanvasPos(x, y)
  if not cx then return end
  
  local tool = TOOLS[curTool]
  
  if tool.name == "Line" or tool.name == "Rect" or tool.name == "Circle" then
    if not tempStart then
      tempStart = {x = cx, y = cy}
      computer.beep(500, 0.05)
    else
      saveState()
      if tool.name == "Line" then
        drawLine(tempStart.x, tempStart.y, cx, cy, curColor, "#")
      elseif tool.name == "Rect" then
        drawRect(tempStart.x, tempStart.y, cx, cy, curColor, "#")
      elseif tool.name == "Circle" then
        local r = math.floor(math.sqrt((cx-tempStart.x)^2 + (cy-tempStart.y)^2))
        drawCircle(tempStart.x, tempStart.y, r, curColor, "#")
      end
      tempStart = nil
      drawCanvas()
      computer.beep(700, 0.1)
    end
    return
  end
  
  if not drawing then
    saveState()
    drawing = true
    lastX, lastY = cx, cy
  end
  
  if lastX and lastY then
    drawLine(lastX, lastY, cx, cy, curColor, "#")
  else
    if tool.name == "Pencil" then
      brush(cx, cy, curColor, "#")
    elseif tool.name == "Eraser" then
      brush(cx, cy, 0, " ")
    elseif tool.name == "Fill" then
      floodFill(cx, cy, curColor)
    elseif tool.name == "Pick" then
      local c = getPixel(cx, cy)
      if c > 0 then curColor = c end
    end
  end
  lastX, lastY = cx, cy
  drawCanvas()
end

local function handleDrag(x, y)
  local cx, cy = getCanvasPos(x, y)
  if not cx then return end
  
  local tool = TOOLS[curTool]
  if tool.name == "Pencil" or tool.name == "Eraser" then
    if lastX and lastY then
      drawLine(lastX, lastY, cx, cy, curColor, tool.name == "Eraser" and " " or "#")
      drawCanvas()
    end
    lastX, lastY = cx, cy
  end
end

initCanvas()
draw()

local lastTouch = nil

while true do
  local ev = {event.pull(0.05)}
  if ev[1] == "touch" then
    local x, y = ev[3], ev[4]
    lastTouch = {x = x, y = y}
    handleTouch(x, y)
  elseif ev[1] == "drag" then
    if lastTouch then
      handleDrag(ev[3], ev[4])
    end
  elseif ev[1] == "drop" then
    drawing = false
    lastX, lastY = nil, nil
    lastTouch = nil
  elseif ev[1] == "key_down" then
    local key = ev[3]
    if key == 14 then undo()
    elseif key == 28 then
      saveState()
      initCanvas()
      drawCanvas()
      computer.beep(400, 0.1)
    end
  end
end
