/*
 Copyright (c) 2015, Apple Inc. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 
 1.  Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.
 
 2.  Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation and/or
 other materials provided with the distribution.
 
 3.  Neither the name of the copyright holder(s) nor the names of any contributors
 may be used to endorse or promote products derived from this software without
 specific prior written permission. No license is granted to the trademarks of
 the copyright holders even if such marks are included in this software.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */


#import "ORKActiveStepViewController.h"

#import "ORKActiveStepTimer.h"
#import "ORKActiveStepTimerView.h"
#import "ORKActiveStepView.h"
#import "ORKNavigationContainerView.h"
#import "ORKStepHeaderView_Internal.h"
#import "ORKVerticalContainerView.h"
#import "ORKVoiceEngine.h"

#import "ORKActiveStepViewController_Internal.h"
#import "ORKStepViewController_Internal.h"
#import "ORKTaskViewController_Internal.h"
#import "ORKRecorder_Internal.h"

#import "ORKHealthQuantityTypeRecorder_Internal.h"

#import "ORKActiveStep_Internal.h"
#import "ORKCollectionResult_Private.h"
#import "ORKResult.h"
#import "ORKOrderedTask_Private.h"
#import "ORKTask.h"
#import "ORKWorkoutStep_Private.h"

#import "ORKAccessibility.h"
#import "ORKCodingObjects.h"
#import "ORKHelpers_Internal.h"
#import "ORKSkin.h"


NSString * const ORKConsolidatedRecorderId = @"recorder_data";


@interface ORKActiveStepViewController () {
    ORKActiveStepView *_activeStepView;
    ORKActiveStepTimer *_activeStepTimer;

    NSArray *_recorderResults;
    
    SystemSoundID _alertSound;
    NSURL *_alertSoundURL;
    BOOL _hasSpokenHalfwayCountdown;
}

@property (nonatomic, strong) NSArray *recorders;

@end


@implementation ORKActiveStepViewController

- (instancetype)initWithStep:(ORKStep *)step {
    
    self = [super initWithStep:step];
    if (self) {
        _recorderResults = [NSArray new];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        _timerUpdateInterval = 1;
    }
    return self;
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    if (self.suspendIfInactive) {
        [self suspend];
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (self.suspendIfInactive) {
        [self resume];
    }
}

- (ORKActiveStep *)activeStep {
    NSAssert(self.step == nil || [self.step isKindOfClass:[ORKActiveStep class]], @"Step should be a subclass of an ORKActiveStep");
    return (ORKActiveStep *)self.step;
}

- (ORKActiveStepView *)activeStepView {
    return _activeStepView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _activeStepView = [[ORKActiveStepView alloc] initWithFrame:self.view.bounds];
    _activeStepView.translatesAutoresizingMaskIntoConstraints = NO;
    [_activeStepView setCustomView:_customView];
    [self updateContinueButtonItem];
    _activeStepView.headerView.learnMoreButtonItem = self.learnMoreButtonItem;
    _activeStepView.continueSkipContainer.skipButtonItem = self.skipButtonItem;
    _activeStepView.continueSkipContainer.continueEnabled = _finished;
    [self.view addSubview:_activeStepView];
    
    NSMutableArray *constraints = [NSMutableArray new];
    [constraints addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[activeStepView]|"
                                                                             options:(NSLayoutFormatOptions)0
                                                                             metrics:nil
                                                                               views:@{@"activeStepView": _activeStepView}]];
    [constraints addObjectsFromArray:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[topLayoutGuide][activeStepView]|"
                                                                             options:(NSLayoutFormatOptions)0
                                                                             metrics:nil
                                                                               views:@{@"activeStepView": _activeStepView,
                                                                                       @"topLayoutGuide": self.topLayoutGuide}]];
    [NSLayoutConstraint activateConstraints:constraints];
    
    [self prepareStep];
}

- (void)stepDidChange {
    [super stepDidChange];
    _activeStepView.activeStep = [self activeStep];
    [self updateContinueButtonItem];
    
    
    [self prepareStep];
}

- (UIView *)customViewContainer {
    __unused UIView *view = [self view];
    return _activeStepView.customViewContainer;
}

- (ORKTintedImageView *)imageView {
    __unused UIView *view = [self view];
    return _activeStepView.imageView;
}

- (void)setCustomView:(UIView *)customView {
    _customView = customView;
    [_activeStepView setStepView:_customView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    ORK_Log_Debug(@"%@",self);

    [self.taskViewController setRegisteredScrollView:_activeStepView];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    ORK_Log_Debug(@"%@",self);
    
    // Wait for animation complete 
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.started){
            // Should call resume instead of start when the task has been started.
            [self resume];
        } else if ([[self activeStep] shouldStartTimerAutomatically]) {
            [self start];
        }
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    ORK_Log_Debug(@"%@",self);
    
    [self suspend];
}

- (void)updateContinueButtonItem {
    _activeStepView.continueSkipContainer.continueButtonItem = self.continueButtonItem;
}

- (void)setContinueButtonItem:(UIBarButtonItem *)continueButtonItem {
    [super setContinueButtonItem:continueButtonItem];
    [self updateContinueButtonItem];
}

- (void)setLearnMoreButtonItem:(UIBarButtonItem *)learnMoreButtonItem {
    [super setLearnMoreButtonItem:learnMoreButtonItem];
    _activeStepView.headerView.learnMoreButtonItem = self.learnMoreButtonItem;
}

- (void)setSkipButtonItem:(UIBarButtonItem *)skipButtonItem {
    [super setSkipButtonItem:skipButtonItem];
    _activeStepView.continueSkipContainer.skipButtonItem = skipButtonItem;
}

- (void)setFinished:(BOOL)finished {
    _finished = finished;
    _activeStepView.continueSkipContainer.continueEnabled = finished;
}

- (ORKStepResult *)result {
    ORKStepResult *sResult = [super result];
    if (_recorderResults) {
        sResult.results = [sResult.results arrayByAddingObjectsFromArray:_recorderResults] ? : _recorderResults;
    }
    return sResult;
}

#pragma mark - transition

- (void)recordersDidChange {
}

- (void)recordersWillStart {
}

- (void)recordersWillStop {
}

- (void)prepareRecorders {
    // Stop any existing recorders
    [self recordersWillStop];
    for (ORKRecorder *recorder in self.recorders) {
        recorder.delegate = nil;
        [recorder stop];
    }
    NSMutableArray *recorders = [NSMutableArray array];
    
    // Setup the consolidated recorder that the other recorders will point at
    ORKDataLogRecorder *sharedRecorder = nil;
    if ([self activeStep].shouldConsolidateRecorders) {
        sharedRecorder = [[ORKDataLogRecorder alloc] initWithIdentifier:ORKConsolidatedRecorderId
                                                                   step:self.step
                                                        outputDirectory:self.outputDirectory];
        sharedRecorder.delegate = self;
        NSError *error = nil;
        sharedRecorder.logger = [sharedRecorder makeJSONDataLoggerWithError:&error];
        if (error) {
            [self recorder:sharedRecorder didFailWithError:error];
            return;
        }
    }
    
    for (ORKRecorderConfiguration * provider in self.activeStep.recorderConfigurations) {
        // If the outputDirectory is nil, recorders which require one will generate an error.
        // We start them anyway, because we don't know which recorders will require an outputDirectory.
        ORKRecorder *recorder = [provider recorderForStep:self.step
                                          outputDirectory:self.outputDirectory];
        recorder.configuration = provider;
        recorder.delegate = self;
        
        // Not all the recorders support using a consolidated log file but the ones that don't
        // will ignore this property.
        recorder.sharedLogger = sharedRecorder.logger;
        
        [recorders addObject:recorder];
    }
    
    // Add the shared recorder last so that it is stopped last.
    if (sharedRecorder) {
        [recorders addObject:sharedRecorder];
    }
    
    self.recorders = recorders;
    
    [self recordersDidChange];
}

- (void)removeRecorder:(ORKRecorder *)recorder {
    recorder.delegate = nil;
    [recorder stop];
    NSMutableArray *recorders = [self.recorders mutableCopy];
    [recorders removeObject:recorder];
    self.recorders = [recorders copy];
}

- (void)setOutputDirectory:(NSURL *)outputDirectory {
    [super setOutputDirectory:outputDirectory];
    [self prepareStep];
}

- (void)prepareStep {
    if (self.activeStep == nil) {
        return;
    }
    
    self.finished = [[self activeStep] startsFinished];
    
    ORK_Log_Debug(@"%@", self);
    _activeStepView.activeStep = self.activeStep;
    
    if ([self.activeStep hasCountDown]) {
        ORKActiveStepTimerView *timerView = [ORKActiveStepTimerView new];
        _activeStepView.activeCustomView = timerView;
    } else {
        _activeStepView.activeCustomView = nil;
    }
    _activeStepView.activeCustomView.activeStepViewController = self;
    [_activeStepView.activeCustomView resetStep:self];
    [self resetTimer];
    
    [self prepareRecorders];
}

- (void)startRecorders {
    [self recordersWillStart];
    // Start recorders
    NSTimeInterval referenceUptime = [self activeStep].shouldConsolidateRecorders ? [NSProcessInfo processInfo].systemUptime : 0;
    for (ORKRecorder *recorder in self.recorders) {
        recorder.referenceUptime = referenceUptime;
        [recorder viewController:self willStartStepWithView:self.customViewContainer];
        [recorder start];
    }
}

- (void)stopRecorders {
    [self recordersWillStop];
    for (ORKRecorder *recorder in self.recorders) {
        [recorder stop];
    }
}

- (void)playSound {
    if (_alertSoundURL == nil) {
        _alertSoundURL = [NSURL URLWithString:@"/System/Library/Audio/UISounds/short_low_high.caf"];
        AudioServicesCreateSystemSoundID((__bridge CFURLRef)(_alertSoundURL), &_alertSound);
    }
    AudioServicesPlaySystemSound(_alertSound);
}

- (void)start {
    ORK_Log_Debug(@"%@",self);
    self.started = YES;
    [self startTimer];
    [_activeStepView.activeCustomView startStep:self];
    
    [self startRecorders];
    
    if (self.activeStep.shouldVibrateOnStart) {
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate);
    }
    
    if (self.activeStep.shouldPlaySoundOnStart) {
        [self playSound];
    }
    
    // Start speech
    if (self.activeStep.hasVoice && self.activeStep.spokenInstruction) {
        // Let VO speak "Step x of y" before the instruction.
        // If VO is not running, the text is spoken immediately.
        ORKAccessibilityPerformBlockAfterDelay(1.5, ^{
            [[ORKVoiceEngine sharedVoiceEngine] speakText:self.activeStep.spokenInstruction];
        });
    }
}

- (void)suspend {
    ORK_Log_Debug(@"%@",self);
    if (self.finished || !self.started) {
        return;
    }
    
    [_activeStepTimer pause];
    [_activeStepView.activeCustomView suspendStep:self];
    
    [self stopRecorders];
}

- (void)resume {
    ORK_Log_Debug(@"%@",self);
    if (self.finished || !self.started) {
        return;
    }
    
    [_activeStepTimer resume];
    [self prepareRecorders];
    [self startRecorders];
    [_activeStepView.activeCustomView resumeStep:self];
}

- (void)finish {
    ORK_Log_Debug(@"%@",self);
    if (self.finished) {
        return;
    }
    
    self.finished = YES;
    [_activeStepTimer pause];
    [_activeStepView.activeCustomView finishStep:self];
    [self stopRecorders];
    if (self.activeStep.shouldPlaySoundOnFinish) {
        [self playSound];
    }
    if (self.activeStep.shouldVibrateOnFinish) {
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate);
    }
    if (self.activeStep.hasVoice && self.activeStep.finishedSpokenInstruction) {
        [[ORKVoiceEngine sharedVoiceEngine] speakText:self.activeStep.finishedSpokenInstruction];
    }
    if (!self.activeStep.startsFinished) {
        if (self.activeStep.shouldContinueOnFinish) {
            [self goForward];
        }
    }
    
    [self stepDidFinish];
}

- (void)dealloc {
    AudioServicesDisposeSystemSoundID(_alertSound);
    NSNotificationCenter *nfc = [NSNotificationCenter defaultCenter];
    [nfc removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [nfc removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
}

#pragma mark - timers

- (NSTimeInterval)stepDuration {
    return self.activeStep.stepDuration;
}

- (void)resetTimer {
    [_activeStepTimer reset];
    _activeStepTimer = nil;
}

- (void)startTimer {
    [self resetTimer];
    
    NSTimeInterval stepDuration = self.stepDuration;
    
    if (stepDuration > 0) {
        ORKWeakTypeOf(self) weakSelf = self;
        _activeStepTimer = [[ORKActiveStepTimer alloc] initWithDuration:stepDuration
                                                        interval:_timerUpdateInterval
                                                         runtime:0
                                                         handler:^(ORKActiveStepTimer *timer, BOOL finished) {
                                                             ORKStrongTypeOf(self) strongSelf = weakSelf;
                                                             [strongSelf countDownTimerFired:timer finished:finished];
                                                         }];
        [_activeStepTimer resume];
    }
}

- (void)countDownTimerFired:(ORKActiveStepTimer *)timer finished:(BOOL)finished {
    if (finished) {
        [self finish];
    }
    NSInteger countDownValue = (NSInteger)round(timer.duration - timer.runtime);
    ORKActiveStepCustomView *customView = _activeStepView.activeCustomView;
    [customView updateDisplay:self];
    
    
    ORKVoiceEngine *voice = [ORKVoiceEngine sharedVoiceEngine];
    
    if (!finished && self.activeStep.shouldSpeakCountDown) {
        // Speak entire countdown if VO is running.
        if (UIAccessibilityIsVoiceOverRunning()) {
            [voice speakInt:countDownValue];
            return;
        }
        
        if (0 < countDownValue && countDownValue <= 3) {
            [voice speakInt:countDownValue];
        }
    }
    
    BOOL isHalfway = !_hasSpokenHalfwayCountdown && timer.runtime > timer.duration / 2.0;
    if (!finished && self.activeStep.shouldSpeakRemainingTimeAtHalfway && !UIAccessibilityIsVoiceOverRunning() && isHalfway) {
        _hasSpokenHalfwayCountdown = YES;
        
        NSDateComponentsFormatter *formatter = [ORKOrderedTask textTimeFormatter];
        NSString *durationString = [formatter stringFromTimeInterval:countDownValue];
        
        NSString *text = [NSString localizedStringWithFormat:ORKLocalizedString(@"COUNTDOWN_SPOKEN_REMAINING_%@", nil), durationString];
        [voice speakText:text];
    }
}

- (BOOL)timerActive {
    return (_activeStepTimer != nil);
}

- (NSTimeInterval)timeRemaining {
    if (_activeStepTimer == nil) {
        return self.activeStep.stepDuration;
    }
    return _activeStepTimer.duration - _activeStepTimer.runtime;
}

- (NSTimeInterval)timePassed {
    return _activeStepTimer.runtime;
}

#pragma mark - action handlers

- (void)stepDidFinish {
}

#pragma mark - ORKRecorderDelegate

- (void)recorder:(ORKRecorder *)recorder didCompleteWithResult:(ORKResult *)result {
    _recorderResults = [_recorderResults arrayByAddingObject:result];
    [self notifyDelegateOnResultChange];
}

- (void)recorder:(ORKRecorder *)recorder didFailWithError:(NSError *)error {
    if (error) {
        ORKStrongTypeOf(self.delegate) strongDelegate = self.delegate;
        if ([strongDelegate respondsToSelector:@selector(stepViewController:recorder:didFailWithError:)]) {
            [strongDelegate stepViewController:self recorder:recorder didFailWithError:error];
        }
        
        // If the recorder returns an error indicating that file write failed, and the output directory was nil,
        // we consider it a fatal error and fail the step. Otherwise, developers might be confused to get
        // no output, just because they did not set an output directory.
        if ([error.domain isEqualToString:NSCocoaErrorDomain] &&
            error.code == NSFileWriteInvalidFileNameError &&
            self.outputDirectory == nil) {
            [strongDelegate stepViewControllerDidFail:self withError:error];
        }
    }
}

static NSString *const _ORKFinishedRestoreKey = @"finished";
static NSString *const _ORKRecorderResultsRestoreKey = @"recorderResults";

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder {
    [super encodeRestorableStateWithCoder:coder];
    
    [coder encodeBool:_finished forKey:_ORKFinishedRestoreKey];
    [coder encodeObject:_recorderResults forKey:_ORKRecorderResultsRestoreKey];
}

- (void)decodeRestorableStateWithCoder:(NSCoder *)coder {
    [super decodeRestorableStateWithCoder:coder];
    
    self.finished = [coder decodeBoolForKey:_ORKFinishedRestoreKey];
    _recorderResults = [coder decodeObjectOfClass:[NSArray class] forKey:_ORKRecorderResultsRestoreKey];
}

#pragma mark - Watch Connectivity

- (void)didReceiveWatchMessage:(ORKWorkoutMessage *)message {
    
    // If this is a change of state message then call the state change
    if (message.workoutState) {
        [self workoutStateChanged:message.workoutState];
    }
    
    if ([message isKindOfClass:[ORKSamplesWorkoutMessage class]]) {
        ORKSamplesWorkoutMessage *samplesMessage = (ORKSamplesWorkoutMessage *)message;
        [self addHeathRecorderQuantitySamples: samplesMessage.samples
                       quantityTypeIdentifier: samplesMessage.quantityTypeIdentifier];
    }
}

- (void)workoutStateChanged:(ORKWorkoutState)workoutState {
    // do nothing
}

- (void)addHeathRecorderQuantitySamples:(NSArray<HKQuantitySample *> *)samples quantityTypeIdentifier:(NSString *)quantityTypeIdentifier {
    for (ORKRecorder *recorder in self.recorders) {
        if ([recorder isKindOfClass:[ORKHealthQuantityTypeRecorder class]]) {
            ORKHealthQuantityTypeRecorder *rec1 = (ORKHealthQuantityTypeRecorder *)recorder;
            if ([rec1.quantityType.identifier isEqualToString:quantityTypeIdentifier]) {
                [rec1 addQuantitySamples:samples];
                break;
            }
        }
    }
}

@end
