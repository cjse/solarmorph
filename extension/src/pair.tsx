import { Action, ActionPanel, Form, Icon, List, popToRoot, showToast, Toast, useNavigation } from "@raycast/api";
import { useState } from "react";
import { helperCall } from "./morph";

interface Login {
  country: string;
  email: string;
  password: string;
  challengeId: string;
}

interface Light {
  serial: string;
  name: string;
}

interface Session {
  token: string;
  accountId: string;
  lights: Light[];
}

// The region of the system locale, for example `SE` from `en-SE`.
const defaultCountry = new Intl.Locale(Intl.DateTimeFormat().resolvedOptions().locale).region ?? "GB";

async function failure(title: string, error: unknown) {
  await showToast({
    style: Toast.Style.Failure,
    title,
    message: error instanceof Error ? error.message : String(error),
  });
}

/** Get the key of the lamp and store it. This is the last step. */
async function save(country: string, session: Session, light: Light) {
  const toast = await showToast({ style: Toast.Style.Animated, title: `Getting the key for ${light.name}…` });
  try {
    await helperCall(["pair-save"], {
      country,
      token: session.token,
      accountId: session.accountId,
      serial: light.serial,
    });
    toast.style = Toast.Style.Success;
    toast.title = `Paired with ${light.name}`;
    toast.message = "All control is local from now on.";
    await popToRoot();
  } catch (error) {
    // A 404 means that the lamp is not registered to this account.
    await failure("Could not get the lamp key", error);
  }
}

/** Step 1: the account. Dyson then sends a one-time code by email. */
export default function Pair() {
  const { push } = useNavigation();
  const [isLoading, setIsLoading] = useState(false);
  // The country is a controlled field, so the submitted value is always the
  // shown value. With `defaultValue` and `storeValue`, a field that the user
  // did not edit failed the validation.
  const [country, setCountry] = useState(defaultCountry);
  const [errors, setErrors] = useState<{ country?: string; email?: string; password?: string }>({});
  const clear = (field: keyof typeof errors) => setErrors((previous) => ({ ...previous, [field]: undefined }));

  async function submit(values: { email: string; password: string }) {
    const email = values.email.trim();
    const found = {
      country: /^[A-Za-z]{2}$/.test(country.trim()) ? undefined : "Use a two-letter code, for example SE",
      email: email ? undefined : "The email is necessary",
      password: values.password ? undefined : "The password is necessary",
    };
    setErrors(found);
    if (found.country || found.email || found.password) {
      return;
    }
    setIsLoading(true);
    try {
      const { challengeId } = await helperCall<{ challengeId: string }>([
        "pair-begin",
        "--country",
        country.trim().toUpperCase(),
        "--email",
        email,
      ]);
      push(<Code login={{ country: country.trim().toUpperCase(), email, password: values.password, challengeId }} />);
    } catch (error) {
      await failure("Could not request the code", error);
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <Form
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Send Code" icon={Icon.Envelope} onSubmit={submit} />
        </ActionPanel>
      }
    >
      <Form.Description text="Pairing gets the key of the lamp from your MyDyson account. It is necessary one time. The lamp must already be in the MyDyson app. The extension sends the password only to Dyson and does not store it." />
      <Form.TextField
        id="country"
        title="Country"
        value={country}
        error={errors.country}
        onChange={(value) => {
          setCountry(value);
          clear("country");
        }}
      />
      <Form.TextField
        id="email"
        title="Email"
        placeholder="The email of your MyDyson account"
        storeValue
        error={errors.email}
        onChange={() => clear("email")}
      />
      <Form.PasswordField id="password" title="Password" error={errors.password} onChange={() => clear("password")} />
    </Form>
  );
}

/** Step 2: the one-time code from the email. */
function Code({ login }: { login: Login }) {
  const { push } = useNavigation();
  const [isLoading, setIsLoading] = useState(false);

  async function submit(values: { otpCode: string }) {
    const otpCode = values.otpCode.trim();
    if (!otpCode) {
      return;
    }
    setIsLoading(true);
    try {
      const session = await helperCall<Session>(["pair-complete"], { ...login, otpCode });
      if (session.lights.length === 0) {
        await failure("No Bluetooth lamp found", "Add the lamp in the MyDyson app first.");
      } else if (session.lights.length === 1) {
        await save(login.country, session, session.lights[0]);
      } else {
        push(<Choose country={login.country} session={session} />);
      }
    } catch (error) {
      await failure("The login failed", error);
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <Form
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Pair" icon={Icon.Link} onSubmit={submit} />
        </ActionPanel>
      }
    >
      <Form.Description text={`Dyson sent a 6-digit code to ${login.email}.`} />
      <Form.TextField id="otpCode" title="Code" autoFocus />
    </Form>
  );
}

/** Step 3, only for an account with more than one lamp. */
function Choose({ country, session }: { country: string; session: Session }) {
  return (
    <List navigationTitle="Choose the Lamp">
      {session.lights.map((light) => (
        <List.Item
          key={light.serial}
          icon={Icon.LightBulb}
          title={light.name}
          subtitle={light.serial}
          actions={
            <ActionPanel>
              <Action title="Pair This Lamp" icon={Icon.Link} onAction={() => save(country, session, light)} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
