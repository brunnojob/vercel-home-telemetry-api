import handler from "../../api/telemetry.ts";
import { adapt } from "../../lib/netlify-adapter.mjs";

export default adapt(handler);
export const config = { path: "/api/telemetry" };
