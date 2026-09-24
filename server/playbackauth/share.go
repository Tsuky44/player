package playbackauth

// Tickets délivrés à un lien de partage plutôt qu'à un compte.
//
// Le visiteur d'un lien n'a pas de compte : c'est le lien qui tient le rôle du
// titulaire. Il renouvelle ses tickets par la route publique du partage, et
// révoquer le lien coupe d'un coup tous les flux qu'il a ouverts — y compris
// une réponse Direct Play déjà en cours, que GuardWriter arrête au bloc suivant.

// perShareTickets borne ce qu'un seul lien peut tenir ouvert. Un lien
// permanent circule, mais une poignée de lectures simultanées suffit à l'usage
// légitime et laisse la place aux comptes du foyer.
const perShareTickets = 4

// IssueShare délivre un ticket de lecture de mediaID au lien shareID.
func (s *Store) IssueShare(shareID, mediaID int) (string, Ticket, error) {
	if shareID <= 0 || mediaID <= 0 {
		return "", Ticket{}, ErrDenied
	}
	return s.issue(Ticket{ShareID: shareID, MediaID: mediaID},
		func(t Ticket) bool { return t.ShareID == shareID }, perShareTickets)
}

// RenewShare repousse l'échéance d'un ticket du lien shareID.
func (s *Store) RenewShare(token string, shareID int) (Ticket, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := Digest(token)
	ticket, ok := s.tickets[key]
	now := s.now()
	if !ok || shareID <= 0 || ticket.ShareID != shareID || !now.Before(ticket.ExpiresAt) {
		return Ticket{}, ErrDenied
	}
	ticket.ExpiresAt = now.Add(TTL)
	ticket.LastActivity = now
	s.tickets[key] = ticket
	s.generation.Add(1)
	return ticket, nil
}

// RevokeShareTicket révoque un ticket du lien shareID, à la fermeture de la
// page.
func (s *Store) RevokeShareTicket(token string, shareID int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := Digest(token)
	if ticket, ok := s.tickets[key]; ok && shareID > 0 && ticket.ShareID == shareID {
		delete(s.tickets, key)
		s.generation.Add(1)
	}
}

// RevokeShare révoque tous les tickets du lien shareID : le lien vient d'être
// supprimé, et ce qu'il avait ouvert doit s'arrêter avec lui.
func (s *Store) RevokeShare(shareID int) {
	if shareID <= 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	revoked := false
	for key, ticket := range s.tickets {
		if ticket.ShareID == shareID {
			delete(s.tickets, key)
			revoked = true
		}
	}
	if revoked {
		s.generation.Add(1)
	}
}
