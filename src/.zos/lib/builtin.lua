-- The apps built into zOS. This is the only list of them: ./package copies each one from apps/ into
-- the system image, and apps.lua stops them being removed.

return {
    "appman",
    "files",
    "terminal",
}
