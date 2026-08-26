import SwiftUI

struct OnboardingOverlay: View {
    @Bindable var onboarding: OnboardingStore


    var body: some View {
        ZStack {
            AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.strong)
                .ignoresSafeArea()
            card
                .frame(
                    width: AppTheme.Onboarding.cardWidth,
                    height: AppTheme.Onboarding.cardHeight
                )
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: AppTheme.Anim.transition), value: onboarding.step)
    }

    private var card: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            cardContent
            footer
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.vertical, AppTheme.Spacing.lgXl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(
                            AppTheme.Border.primaryColor,
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
        .shadow(AppTheme.Shadow.lg)
    }

    @ViewBuilder
    private var cardContent: some View {
        let content = stepContent
            .id(onboarding.step)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, AppTheme.Spacing.xxl)
            .padding(.top, AppTheme.Spacing.xxl)
            .padding(.bottom, contentBottomPadding)
        if onboarding.step == .discovery || onboarding.step == .account {
            ScrollView { content }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch onboarding.step {
        case .welcome:
            OnboardingWelcomeStep()
        case .discovery:
            OnboardingQuestionnaireStep(
                onboarding: onboarding,
                title: L10n.string("Quick questions"),
                questions: OnboardingQuestion.discoveryQuestions
            )
        case .profile:
            OnboardingQuestionnaireStep(
                onboarding: onboarding,
                title: L10n.string("Tell us about your work"),
                questions: OnboardingQuestion.profileQuestions
            )
        case .account:
            OnboardingAccountStep(sampleState: onboarding.sampleState)
        }
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if onboarding.step != .welcome {
                secondaryButton(L10n.string("Back"), action: onboarding.goBack)
            }
            Spacer()
            switch onboarding.step {
            case .welcome:
                primaryButton(L10n.string("Continue"), action: onboarding.advance)
            case .discovery:
                primaryButton(L10n.string("Continue"), action: onboarding.advance)
            case .profile:
                primaryButton(L10n.string("Continue"), action: onboarding.submitSurvey)
            case .account:
                secondaryButton(L10n.string("Skip"), action: onboarding.skip, disabled: false)
                primaryButton(
                    onboarding.sampleState == .loading
                        ? L10n.string("Loading…")
                        : L10n.string("Tutorial"),
                    action: onboarding.openSampleProject
                )
            }
        }
    }

    private var contentBottomPadding: CGFloat {
        switch onboarding.step {
        case .profile, .discovery:
            AppTheme.Spacing.md
        case .welcome, .account:
            AppTheme.Spacing.xxl
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.capsule(.prominent, size: .regular))
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
    }

    private func secondaryButton(
        _ label: String,
        action: @escaping () -> Void,
        disabled: Bool? = nil
    ) -> some View {
        Button(label, action: action)
            .buttonStyle(.capsule(
                .secondary,
                size: .regular,
                fill: AnyShapeStyle(AppTheme.Onboarding.secondaryButtonFill)
            ))
            .disabled(disabled ?? isBusy)
    }

    private var isBusy: Bool { onboarding.sampleState == .loading }
}
