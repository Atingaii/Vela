//! NotchWindowController.apply(edge:): only the newest crossing may land/reveal.
//! Per-window state also keeps unrelated layout refreshes from moving a fading panel.

#[derive(Default)]
pub struct Transition {
    presented: Option<String>,
    sequence: u32,
    pending: Option<Pending>,
}

struct Pending {
    edge: String,
    generation: u32,
    landed: bool,
    fading: bool,
}

#[derive(Debug, PartialEq)]
pub enum Placement {
    Place,
    Wait,
    Fade(u32),
}

impl Transition {
    pub fn observe(&mut self, edge: &str) -> Placement {
        if let Some(pending) = &self.pending {
            if pending.edge == edge {
                return if pending.landed { Placement::Place } else { Placement::Wait };
            }
        } else if self.presented.as_deref().is_none_or(|current| current == edge) {
            self.presented = Some(edge.to_owned());
            return Placement::Place;
        }
        self.sequence = self.sequence.wrapping_add(1).max(1);
        self.pending = Some(Pending { edge: edge.to_owned(), generation: self.sequence, landed: false, fading: false });
        Placement::Fade(self.sequence)
    }

    pub fn begin_fade(&mut self, generation: u32) -> bool {
        let Some(pending) = &mut self.pending else { return false; };
        if pending.generation != generation || pending.landed || pending.fading { return false; }
        pending.fading = true;
        true
    }

    pub fn land(&mut self, generation: u32) -> Option<String> {
        let pending = self.pending.as_mut()?;
        if pending.generation != generation || pending.landed { return None; }
        pending.landed = true;
        self.presented = Some(pending.edge.clone());
        self.presented.clone()
    }

    pub fn reveal(&mut self, generation: u32) -> bool {
        if !self.pending.as_ref().is_some_and(|p| p.generation == generation && p.landed) { return false; }
        self.pending = None;
        true
    }

    pub fn pending(&self) -> bool { self.pending.is_some() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unrelated_placement_waits_for_fade_but_landed_geometry_can_settle() {
        let mut state = Transition::default();
        assert_eq!(state.observe("right"), Placement::Place);
        assert_eq!(state.observe("left"), Placement::Fade(1));
        assert_eq!(state.observe("left"), Placement::Wait);
        assert!(!state.reveal(1));
        assert!(state.begin_fade(1));
        assert!(!state.begin_fade(1));
        assert_eq!(state.land(1).as_deref(), Some("left"));
        assert_eq!(state.observe("left"), Placement::Place);
        assert!(state.reveal(1));
        assert!(!state.pending());
    }

    #[test]
    fn rapid_reversal_invalidates_both_old_completion_and_old_reveal() {
        let mut state = Transition::default();
        state.observe("right");
        assert_eq!(state.observe("left"), Placement::Fade(1));
        assert_eq!(state.observe("right"), Placement::Fade(2));
        assert!(!state.begin_fade(1));
        assert_eq!(state.land(1), None);
        assert_eq!(state.land(2).as_deref(), Some("right"));
        assert_eq!(state.observe("top"), Placement::Fade(3));
        assert!(!state.reveal(2));
        assert_eq!(state.land(3).as_deref(), Some("top"));
        assert!(state.reveal(3));
    }

    #[test]
    fn panels_do_not_share_generation_or_presented_edge() {
        let mut first = Transition::default();
        let mut second = Transition::default();
        first.observe("left"); second.observe("top");
        first.observe("right");
        assert_eq!(second.observe("top"), Placement::Place);
        assert!(!second.reveal(1));
        assert!(first.pending());
    }
}
