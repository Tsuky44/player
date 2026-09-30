package otp

import (
	"strings"
	"testing"
	"time"
)

// Vecteurs de RFC 6238, annexe B, pour SHA-1 : le secret ASCII
// "12345678901234567890" et les six derniers chiffres des codes à huit.
func TestCodesMatchTheRFC6238Vectors(t *testing.T) {
	secret := secretEncoding.EncodeToString([]byte("12345678901234567890"))
	for _, tc := range []struct {
		unix int64
		want string
	}{
		{59, "287082"},
		{1111111109, "081804"},
		{1111111111, "050471"},
		{1234567890, "005924"},
		{2000000000, "279037"},
	} {
		got, err := CodeAt(secret, time.Unix(tc.unix, 0))
		if err != nil {
			t.Fatal(err)
		}
		if got != tc.want {
			t.Errorf("t=%d: code %s, want %s", tc.unix, got, tc.want)
		}
	}
}

func TestACodeIsAcceptedAroundItsPeriodButNeverTwice(t *testing.T) {
	secret, err := GenerateSecret()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_700_000_000, 0)
	code, _ := CodeAt(secret, now)

	step, ok := MatchTOTP(secret, code, now.Add(25*time.Second), 0)
	if !ok || step != Step(now) {
		t.Fatalf("a code typed just after it changed must still pass (ok=%v step=%d)", ok, step)
	}
	if _, ok := MatchTOTP(secret, code, now, step); ok {
		t.Fatal("a code already accepted must not be replayed")
	}
	if _, ok := MatchTOTP(secret, code, now.Add(2*time.Minute), 0); ok {
		t.Fatal("a code two minutes old must be refused")
	}
	spaced := code[:3] + " " + code[3:]
	if _, ok := MatchTOTP(secret, spaced, now, 0); !ok {
		t.Fatal("spaces typed to read the code back must be ignored")
	}
}

func TestPolicyDecidesWhatTheLoginStillAsks(t *testing.T) {
	for _, tc := range []struct {
		policy               Policy
		enrolled, privileged bool
		want                 LoginStep
	}{
		{Disabled, true, true, StepNone},
		{Optional, false, true, StepNone},
		{Optional, true, false, StepCode},
		{Admins, false, false, StepNone},
		{Admins, false, true, StepSetup},
		{Admins, true, false, StepCode},
		{Everyone, false, false, StepSetup},
	} {
		if got := tc.policy.NextLoginStep(tc.enrolled, tc.privileged); got != tc.want {
			t.Errorf("%s enrolled=%v privileged=%v: step %d, want %d",
				tc.policy, tc.enrolled, tc.privileged, got, tc.want)
		}
	}
	if _, ok := ParsePolicy("sometimes"); ok {
		t.Error("an unknown policy must be refused")
	}
}

func TestARecoveryCodeWorksOnceWhateverItsCase(t *testing.T) {
	codes, digests, err := NewRecoveryCodes()
	if err != nil {
		t.Fatal(err)
	}
	if len(codes) != RecoveryCodeCount || len(digests) != RecoveryCodeCount {
		t.Fatalf("%d codes, %d digests", len(codes), len(digests))
	}
	stored := encodeDigests(digests)
	if strings.Contains(stored, codes[0]) {
		t.Fatal("recovery codes must only be stored as digests")
	}

	remaining, ok := consumeRecovery(stored, strings.ToUpper(codes[3]))
	if !ok || len(decodeDigests(remaining)) != RecoveryCodeCount-1 {
		t.Fatalf("consume: ok=%v, %d left", ok, len(decodeDigests(remaining)))
	}
	if _, ok := consumeRecovery(remaining, codes[3]); ok {
		t.Fatal("a recovery code must not work twice")
	}
}

func TestAChallengeDiesAfterItsAttemptsOrItsLifetime(t *testing.T) {
	now := time.Unix(0, 0)
	s := NewChallengesForTest(time.Minute, func() time.Time { return now })
	token, err := s.Issue(Challenge{UserID: 7})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < MaxAttempts; i++ {
		if _, ok := s.Attempt(token); !ok {
			t.Fatalf("attempt %d refused", i+1)
		}
	}
	if _, ok := s.Attempt(token); ok {
		t.Fatal("a challenge must stop after MaxAttempts codes")
	}

	token, _ = s.Issue(Challenge{UserID: 7})
	now = now.Add(time.Minute)
	if _, ok := s.Attempt(token); ok {
		t.Fatal("an expired challenge must be refused")
	}
}
