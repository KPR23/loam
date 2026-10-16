// Turns an activity event into the text of a push. Mirrors ActivityEvent.headline
// in the app and the category rules in private.notification_category.

export interface PushEvent {
  kind: string;
  actor_id: string;
  actor_name: string;
  recipient_id: string | null;
  recipient_name: string | null;
  expense_id: string | null;
  repayment_id: string | null;
  expense_title: string;
  affected_share_minor: number;
  currency: string;
}

export interface PushContent {
  title: string;
  body: string;
  category: "requests" | "replies" | "changes" | "repayments";
}

const REQUESTS = new Set(["shared", "proposal_created"]);
const REPLIES = new Set(["accepted", "rejected", "proposal_accepted", "proposal_rejected", "auto_accepted"]);
const REPAYMENTS = new Set(["repayment_recorded", "repayment_reversed", "repayment_received"]);

export function notificationCategory(kind: string): PushContent["category"] {
  if (REQUESTS.has(kind)) return "requests";
  if (REPLIES.has(kind)) return "replies";
  if (REPAYMENTS.has(kind)) return "repayments";
  return "changes";
}

function possessive(name: string): string {
  if (name === "you") return "your";
  return name.endsWith("s") ? `${name}'` : `${name}'s`;
}

function money(minor: number, currency: string): string {
  try {
    return new Intl.NumberFormat("pl-PL", { style: "currency", currency }).format(minor / 100);
  } catch {
    return `${(minor / 100).toFixed(2)} ${currency}`;
  }
}

// Returns null for kinds this build doesn't know, so a newer app version's events never send garbage.
export function pushContent(event: PushEvent, viewerId: string): PushContent | null {
  const actor = event.actor_name || "Someone";
  const recipient = event.recipient_id === viewerId ? "you" : (event.recipient_name ?? "a participant");
  const title = event.expense_title.trim() || "Expense";
  const category = notificationCategory(event.kind);
  const reply = (body: string, heading = title): PushContent => ({ title: heading, body, category });
  switch (event.kind) {
    case "shared": return reply(`${actor} shared this with you`);
    case "accepted": return reply(`${actor} accepted this expense`);
    case "rejected": return reply(`${actor} declined this expense`);
    case "proposal_accepted": return reply(`${actor} accepted ${possessive(recipient)} changes`);
    case "proposal_rejected": return reply(`${actor} declined ${possessive(recipient)} changes`);
    case "edited": return reply(`${actor} edited this expense`);
    case "participant_removed": return reply(`${actor} removed you from this expense`);
    case "deleted": return reply(`${actor} deleted this expense`);
    case "proposal_created": return reply(`${actor} suggested changes`);
    case "auto_accepted": return reply("This expense was accepted automatically");
    case "proposal_superseded": return reply(`${possessive(actor)} suggested changes were replaced`);
    case "repayment_recorded":
      return reply(`${actor} paid you back ${money(event.affected_share_minor, event.currency)}`, "Repayment");
    case "repayment_received":
      return reply(`${actor} recorded that you paid them back ${money(event.affected_share_minor, event.currency)}`, "Repayment");
    case "repayment_reversed":
      return reply(`${actor} reversed a repayment of ${money(event.affected_share_minor, event.currency)}`, "Repayment");
    default: return null;
  }
}
