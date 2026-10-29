-- zOS Calculator: evaluates expressions like 2 * (3 + 4), sqrt(2) or x = pi / 4.

local ui = zos.ui

-- Expressions run in a sandbox that only contains maths functions and variables.
local env = { ans = 0, ln = math.log }
for name, fn in pairs(math) do env[name] = fn end

local function format(n)
  if n ~= n then return "not a number" end
  if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
  return string.format("%.10g", n)
end

local function evaluate(input)
  local name, expr = input:match("^%s*([%a_][%w_]*)%s*=%s*([^=].*)$")
  local fn = load("return " .. (expr or input), "=calc", "t", env)
  if not fn then return nil, "syntax error" end
  local ok, result = pcall(fn)
  if not ok then return nil, (tostring(result):gsub("^calc:%d+: ", "")) end
  if type(result) ~= "number" then return nil, "result is not a number" end
  if name then env[name] = result end
  env.ans = result
  return result
end

local history = {}
while true do
  local w, h = term.getSize()
  ui.screen("Calculator", "empty line: quit")
  ui.text("Try 2^10, sqrt(2), sin(pi/2), floor(ans/3) or x = 5 * 3", ui.theme.dim)
  ui.text("")
  local _, top = term.getCursorPos()
  local room = h - top - 1
  for i = math.max(1, #history - room + 1), #history do
    ui.at(2, top, history[i][1]:sub(1, w - 2), history[i][2])
    top = top + 1
  end
  term.setCursorPos(2, top)

  local input = ui.input()
  if input == "" then return end
  local result, err = evaluate(input)
  if result then
    history[#history + 1] = { input .. " = " .. format(result), ui.theme.fg }
  else
    history[#history + 1] = { input .. ": " .. err, ui.theme.bad }
  end
end
