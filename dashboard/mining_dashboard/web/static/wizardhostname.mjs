// The coordinator name shares dashboard.host with the later Configuration view.
import { pathGet } from "./configsync.mjs";
import { html } from "./preact.mjs";
import { Field, Note } from "./wizardparts.mjs";

export function MachineName({ cfg, edit }) {
  const host = pathGet(cfg, "dashboard.host");
  return html`<${Field} label="Name this machine">
    <input name="machine_name" value=${host && host !== "auto" ? host : "pithead"}
      onInput=${edit("dashboard.host")} required maxlength="63"
      pattern=${String.raw`[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?`}
      autocomplete="off" autocapitalize="off" spellcheck=${false} />
    <//><${Note}>Use 1–63 letters, digits or hyphens; start and end with a letter or digit.
    The dashboard opens at https://&lt;name&gt;.local. Change this later in Configuration.<//>`;
}
