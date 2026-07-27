/**
 * What to show a worker for each failure this client can produce.
 *
 * The envelope's own documentation says `code` is the machine-readable
 * discriminator and `message` is "for a human reading a log". So the server's
 * message is not rendered: it is written for whoever is debugging, it is not
 * translated, and "the log-in request could not be recorded" is not something
 * to put in front of somebody trying to start a shift. The copy lives here,
 * keyed on the code.
 *
 * `fields` is the exception and is rendered as it arrives. Those messages come
 * from Ecto's changeset traversal, they name an input the worker filled in, and
 * substituting our own would mean re-deriving the validation rules on this side
 * to know which one failed.
 *
 * The switches are exhaustive and the linter fails the build when a new member
 * of either union is added without a copy line here.
 */

import type { ApiError, ApiFieldError, RequestFailure } from "../api/errors";

export function failureMessage(failure: RequestFailure): string {
  switch (failure.kind) {
    case "network_error":
      return "The server could not be reached. Check your connection and try again.";
    case "malformed_response":
      return `The server answered in a way this client does not understand (${failure.status}). Nothing was changed.`;
    case "api_error":
    case "api_field_error":
      return apiFailureMessage(failure);
  }
}

function apiFailureMessage(failure: ApiError | ApiFieldError): string {
  switch (failure.code) {
    case "bad_request":
      return "That request was incomplete. Fill in the field and try again.";
    case "unauthorized":
      return "That is no longer valid. Ask for a new link.";
    case "not_found":
      return "That address does not exist on this server.";
    case "unprocessable_entity":
      return "That was not accepted.";
    case "internal_server_error":
      return "Something went wrong on the server. Nothing was changed; try again.";
    case "bad_gateway":
      return "The email could not be sent right now. Try again in a moment.";
    case "unrecognised":
      return `The server refused with a status this client does not know about (${failure.status}).`;
  }
}
