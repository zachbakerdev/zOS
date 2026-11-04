-- Builds zos.tar.gz system images for the tests, with zOS's own tar and compression libraries.
-- See specs/formats/TGZ_FORMAT.md.
--
--     local tgz = require("tgz")
--     tgz({ ["/startup.lua"] = "-- startup" })       a gzipped ustar archive of those files
--     tgz(files, { { name = "x", type = "symlink", linkname = "y" } })   with extra raw entries

package.path = "src/.zos/lib/?.lua;" .. package.path
local tar = require("tar")

return function(files, extra)
  local paths = {}
  for path in pairs(files) do paths[#paths + 1] = path end
  table.sort(paths)
  local entries = {}
  for _, path in ipairs(paths) do
    entries[#entries + 1] = { name = path:gsub("^/", ""), data = files[path], mtime = 0 }
  end
  for _, entry in ipairs(extra or {}) do
    entry.mtime = entry.mtime or 0
    entries[#entries + 1] = entry
  end
  return assert(tar.create(entries, { format = "ustar", gzip = 9 }))
end
