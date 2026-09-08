"""Side-effect-free validation for the wizard's destructive install request."""


def validate_install_request(form: dict, disks: list[dict]) -> dict:
    """Return the normalized request, or raise before any spool marker is published."""
    disk = str(form.get("disk", "")).strip()
    confirm = str(form.get("confirm", "")).strip()
    wipe = str(form.get("wipe", "keep")).strip() or "keep"
    by_name = {item["name"]: item for item in disks}
    if disk not in by_name:
        raise ValueError("choose a disk from the list")
    if confirm != disk:
        raise ValueError(f"type {disk} exactly to confirm")
    if wipe not in ("keep", "data", "all"):
        raise ValueError("unknown wipe mode")
    if wipe != "keep" and by_name[disk]["state"] != "pithead-with-data":
        wipe = "keep"
    return {"disk": disk, "wipe": wipe}
