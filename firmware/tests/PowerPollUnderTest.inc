void idlePowerPollSupply(bool force = false) {
  const uint32_t now = millis();
  if (!force && idlePowerSupply.sampled &&
      (uint32_t)(now - idlePowerSupply.checkedAt) < 500) return;
  const bool wasKnown = idlePowerSupply.sampled && idlePowerSupply.valid &&
      uint32_t(now-idlePowerSupply.checkedAt)<=1500;
  const bool wasBattery = idlePowerSupply.batteryOnly;
  const int status = pmuOK ? pmuRead(0x00) : -1;
  idlePowerSupplyUpdate(&idlePowerSupply, now, status);
  // Unplugging / recovering a valid battery-only reading starts a full interval.
  if (idlePowerSupply.valid && (!wasKnown || wasBattery != idlePowerSupply.batteryOnly))
    idlePowerOffReset(&idlePowerOffTimer, now);
}
