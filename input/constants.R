
PERCVTIME = 300
rbn.registerSetting("RESAMPLINGTIMEOUTS",
  c(0.8, 0.9, 0.9, 1.0, 1.0,
    1.0, 1.0, 1.1, 1.1, 1.2) * PERCVTIME)


rbn.registerSetting("SUPERRATE", 0.01)

rbn.registerSetting("SAMPLING_TRAFO", "default")