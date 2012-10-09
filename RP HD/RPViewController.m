//
//  RPViewController.m
//  RP HD
//
//  Created by Giacomo Tufano on 15/03/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import "RPViewController.h"
#import "RPAppDelegate.h"
#import <MediaPlayer/MediaPlayer.h>
#import "LocalyticsSession.h"
#import "STKeychain/STKeychain.h"
#import "SongAdder.h"
#import "Song.h"

@interface RPViewController () <UIPopoverControllerDelegate, RPLoginControllerDelegate, AVAudioSessionDelegate>

@end

@implementation RPViewController

#pragma mark -
#pragma mark HD images loading

-(void)scheduleImagesTimer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval howMuchTimeBetweenImages;
        switch (self.bitrateSelector.selectedSegmentIndex) {
            case 0:
                howMuchTimeBetweenImages = 60.0;
                break;
            case 1:
                howMuchTimeBetweenImages = 40.0;
                break;
            case 2:
                howMuchTimeBetweenImages = 20.0;
                break;
            default:
                break;
        }
        self.theImagesTimer = [NSTimer scheduledTimerWithTimeInterval:howMuchTimeBetweenImages target:self selector:@selector(loadNewImage:) userInfo:nil repeats:YES];
        // While we are at it, let's load a first image...
        [self loadNewImage:nil];
        DLog(@"Scheduling images timer (%@) setup to %f.0 seconds", self.theImagesTimer, howMuchTimeBetweenImages);
    });
}

-(void)unscheduleImagesTimer
{
    DLog(@"Unscheduling images timer (%@)", self.theImagesTimer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.theImagesTimer invalidate];
        self.theImagesTimer = nil;
    });
}

-(void)loadNewImage:(NSTimer *)timer
{
    NSMutableURLRequest *req;
    if(self.isPSDPlaying)
    {
        DLog(@"Requesting PSD image");
        req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:kHDImagePSDURL]];
        [req addValue:self.cookieString forHTTPHeaderField:@"Cookie"];
    }
    else
    {
        req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:kHDImageURLURL]];
    }
    [req setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    [req addValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
     {
         if(data)
         {
             NSString *imageUrl = [[[NSString alloc]  initWithBytes:[data bytes] length:[data length] encoding: NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
             if(imageUrl)
             {
                 NSURLRequest *req = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:imageUrl]];
                 [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
                  {
                      if(data)
                      {
                          UIImage *temp = [UIImage imageWithData:data];
                          DLog(@"Loaded %@, sending it to screen", [res URL]);
                          // Protect from 404's
                          if(temp)
                          {
                              // load image on the main thread
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  [self.hdImage setImage:temp];
                                  // If we have a second screen, update also there
                                  if ([[UIScreen screens] count] > 1)
                                      [((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).TVviewController.TVImage setImage:temp];
                              });
                          }
                      }
                      else
                      {
                          DLog(@"Failed loading image from: <%@>", [res URL]);
                      }
                  }];
             }
             else {
                 DLog(@"Got an invalid URL");
             }
         }
     }];
}

#pragma mark -
#pragma mark Metadata management

-(void)metatadaHandler:(NSTimer *)timer
{
    // This function get metadata directly in case of PSD (no stream metadata)
    DLog(@"This is metatadaHandler: called %@", (timer == nil) ? @"directly" : @"from the 'self-timer'");
    // Get song name first
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:@"http://www.radioparadise.com/ajax_rp2_playlist_ipad.php"]];
    // Shutdown cache (don't) and cookie management (we'll send them manually, if needed)
    [req setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    [req addValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [req setHTTPShouldHandleCookies:NO];
    // Add cookies only for PSD play
    if(self.isPSDPlaying)
        [req addValue:self.cookieString forHTTPHeaderField:@"Cookie"];
    [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
     {
         DLog(@"metadata received %@ ", (data) ? @"successfully." : @"with errors.");
         if(data)
         {
             // Get name and massage it (it's web encoded and with triling spaces)
             NSString *stringData = [[NSString alloc]  initWithBytes:[data bytes] length:[data length] encoding: NSUTF8StringEncoding];
             NSArray *values = [stringData componentsSeparatedByString:@"|"];
             if([values count] != 4)
             {
                 NSLog(@"Error in reading metadata from http://www.radioparadise.com/ajax_rp2_playlist_ipad.php: <%@> received.", stringData);
                 return;
             }
             NSString *metaText = [values objectAtIndex:0];
             metaText = [metaText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
             metaText = [metaText stringByReplacingOccurrencesOfString:@"&mdash;" withString:@"-"];
             dispatch_async(dispatch_get_main_queue(), ^{
                 self.metadataInfo.text = metaText;
                 // If we have a second screen, update also there
                 if ([[UIScreen screens] count] > 1)
                     ((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).TVviewController.songNameOnTV.text = metaText;
                 // Update metadata info
                 NSArray *songPieces = [metaText componentsSeparatedByString:@" - "];
                 if([songPieces count] == 2)
                 {
                     NSDictionary *mpInfo;
                     self.coverImage = nil;
                     MPMediaItemArtwork *albumArt = [[MPMediaItemArtwork alloc] initWithImage:[UIImage imageNamed:@"RP-meta"]];
                     mpInfo = @{MPMediaItemPropertyArtist: [songPieces objectAtIndex:0],
                               MPMediaItemPropertyTitle: [songPieces objectAtIndex:1],
                               MPMediaItemPropertyArtwork: albumArt};
                     [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:mpInfo];
                     DLog(@"set MPNowPlayingInfoCenter to \"%@ - %@\"", mpInfo[MPMediaItemPropertyArtist], mpInfo[MPMediaItemPropertyTitle]);
                 }
             });
             // remembering songid for forum view
             self.psdSongId = [values objectAtIndex:1];
             // In any case, reset the "add song" button to enabled state (we have a new song, it seems).
             self.addSongButton.enabled = YES;
             // Set a timer to refresh ourselves if this is the standard stream.
             if(!self.isPSDPlaying)
             {
                 if(self.theStreamMetadataTimer != nil)
                 {
                     [self.theStreamMetadataTimer invalidate];
                     self.theStreamMetadataTimer = nil;
                 }
                 NSNumber *whenRefresh = [values objectAtIndex:2];
                 if([whenRefresh intValue] <= 0)
                 {
                     whenRefresh = @([whenRefresh intValue] * -1);
                     if([whenRefresh intValue] < 5)
                         whenRefresh = @(5);
                     DLog(@"We're into the fade out... skipping %@ seconds", whenRefresh);
                 }
                 else
                     DLog(@"This song will last for %.0f seconds, rescheduling ourselves for refresh", [whenRefresh doubleValue]);
                 dispatch_async(dispatch_get_main_queue(), ^{
                     self.theStreamMetadataTimer = [NSTimer scheduledTimerWithTimeInterval:[whenRefresh doubleValue] target:self selector:@selector(metatadaHandler:) userInfo:nil repeats:NO];
                 });
             }
             // Now get almbum artwork
             NSString *temp = [NSString stringWithFormat:@"http://www.radioparadise.com/graphics/covers/l/%@.jpg", [values objectAtIndex:3]];
             DLog(@"URL for Artwork: <%@>", temp);
             [self.imageLoadQueue cancelAllOperations];
             NSURLRequest *req = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:temp]];
             [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
              {
                  if(data)
                  {
                      self.coverImage = [UIImage imageWithData:data];
                      // Update metadata info
                      if(self.coverImage != nil)
                      {
                          // Update cover art cache
                          MPMediaItemArtwork *albumArt = [[MPMediaItemArtwork alloc] initWithImage:self.coverImage];
                          NSString *artist = [[[MPNowPlayingInfoCenter defaultCenter] nowPlayingInfo] objectForKey:MPMediaItemPropertyArtist];
                          if(!artist)
                              artist = @"";
                          NSString *title = [[[MPNowPlayingInfoCenter defaultCenter] nowPlayingInfo] objectForKey:MPMediaItemPropertyTitle];
                          if(!title)
                              title = @"";
                          dispatch_async(dispatch_get_main_queue(), ^{
                              NSDictionary *mpInfo;
                              mpInfo = @{MPMediaItemPropertyArtist: artist,
                                        MPMediaItemPropertyTitle: title,
                                        MPMediaItemPropertyArtwork: albumArt};
                              [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:mpInfo];
                              DLog(@"set MPNowPlayingInfoCenter (with album) to \"%@ - %@\"", mpInfo[MPMediaItemPropertyArtist], mpInfo[MPMediaItemPropertyTitle]);
                              [self.rpWebButton setBackgroundImage:self.coverImage forState:UIControlStateNormal];
                              [self.rpWebButton setBackgroundImage:self.coverImage forState:UIControlStateHighlighted];
                              [self.rpWebButton setBackgroundImage:self.coverImage forState:UIControlStateSelected];
                          });
                      }
                  }
                  else
                  {
                      dispatch_async(dispatch_get_main_queue(), ^{
                          [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateNormal];
                          [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateHighlighted];
                          [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateSelected];
                      });
                 }
              }];
         }
     }];
}

-(void)tvExternalScreenInited:(NSNotification *)note
{
    // copy metadata and current HD image
    if ([[UIScreen screens] count] > 1)
    {
        ((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).TVviewController.songNameOnTV.text = self.metadataInfo.text;
        [((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).TVviewController.TVImage setImage:self.hdImage.image];
    }

}

#pragma mark -
#pragma mark Actions

- (void)playMainStream
{
    [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"playMainStream"];
    [self interfacePlayPending];
    self.theStreamer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:self.theRedirector]];
    [self activateNotifications];
    [self.theStreamer play];
}

-(void)setupFading:(AVPlayer *)stream fadeOut:(BOOL)isFadingOut startingAt:(CMTime)start ending:(CMTime)end
{
    DLog(@"This is setupFading fading %@ stream %@ from %lld to %lld", isFadingOut ? @"out" : @"in", stream, start.value/start.timescale, end.value/end.timescale);
    // AVPlayerObject is a property which points to an AVPlayer
    AVPlayerItem *myAVPlayerItem = stream.currentItem;
    AVAsset *myAVAsset = myAVPlayerItem.asset;
    NSArray *audioTracks = [myAVAsset tracksWithMediaType:AVMediaTypeAudio];
    
    NSMutableArray *allAudioParams = [NSMutableArray array];
    for (AVAssetTrack *track in audioTracks)
    {
        AVMutableAudioMixInputParameters *audioInputParams = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
        if(isFadingOut)
            [audioInputParams setVolumeRampFromStartVolume:1.0 toEndVolume:0 timeRange:CMTimeRangeFromTimeToTime(start, end)];
        else
            [audioInputParams setVolumeRampFromStartVolume:0 toEndVolume:1.0 timeRange:CMTimeRangeFromTimeToTime(start, end)];
        DLog(@"Adding %@ to allAudioParams", audioInputParams);
        [allAudioParams addObject:audioInputParams];
    }
    AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
    [audioMix setInputParameters:allAudioParams];
    [myAVPlayerItem setAudioMix:audioMix];
}

-(void)presetFadeOutToCurrentTrack:(AVPlayer *)streamToBeFaded startingAt:(int)start forSeconds:(int)duration
{
    DLog(@"This is presetFadeOutToCurrentTrack called for %@, starting at %d and for %d seconds.", streamToBeFaded, start, duration);
    [self setupFading:streamToBeFaded fadeOut:YES startingAt:CMTimeMake(start, 1) ending:CMTimeMake(start + duration, 1)];
}

-(void)fadeOutCurrentTrackNow:(AVPlayer *)streamToBeFaded forSeconds:(int)duration
{
    int32_t preferredTimeScale = 600;
    CMTime durationTime = CMTimeMakeWithSeconds((Float64)duration, preferredTimeScale);
    CMTime startTime = streamToBeFaded.currentItem.currentTime;
    CMTime endTime = CMTimeAdd(startTime, durationTime);
    DLog(@"This is fadeOutCurrentTrackNow called for %@ and %d seconds (current time is %lld).", streamToBeFaded, duration, startTime.value/startTime.timescale);
    [self setupFading:streamToBeFaded fadeOut:YES startingAt:startTime ending:endTime];
}

-(void)fadeInCurrentTrackNow:(AVPlayer *)streamToBeFaded forSeconds:(int)duration
{
    int32_t preferredTimeScale = 600;
    CMTime durationTime = CMTimeMakeWithSeconds((Float64)duration, preferredTimeScale);
    CMTime startTime = streamToBeFaded.currentItem.currentTime;
    CMTime endTime = CMTimeAdd(startTime, durationTime);
    DLog(@"This is fadeInCurrentTrackNow called for %@ and %d seconds (current time is %lld).", streamToBeFaded, duration, startTime.value/startTime.timescale);
    [self setupFading:streamToBeFaded fadeOut:NO startingAt:startTime ending:endTime];
}

-(void)stopPsdFromTimer:(NSTimer *)aTimer
{
    DLog(@"This is the PSD timer triggering the end of the PSD song");
    // If still playing PSD, restart "normal" stream
    if(self.isPSDPlaying)
    {
        [self interfacePlayPending];
        self.isPSDPlaying = NO;
        if(self.thePsdTimer)
        {
            [self.thePsdTimer invalidate];
            self.thePsdTimer = nil;
        }
        DLog(@"Stopping stream in timer firing (starting fade out)");
        [self unscheduleImagesTimer];
        // restart main stream...
        [self playMainStream];
        // ...while giving the delay to the fading
        [self.thePsdStreamer removeObserver:self forKeyPath:@"status"];
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, kPsdFadeOutTime * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            DLog(@"PSD stream now stopped!");
            [self.thePsdStreamer pause];
            self.thePsdStreamer = nil;
        });
    }
}

// Here PSD streaming is ready to start (and it is started)
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    DLog(@"*** observeValueForKeyPath:ofObject:change:context called!");
    if (object == self.thePsdStreamer && [keyPath isEqualToString:@"status"])
    {
        if (self.thePsdStreamer.status == AVPlayerStatusReadyToPlay)
        {
            DLog(@"psdStreamer is ReadyToPlay for %@ secs", self.psdDurationInSeconds);
            // reduce psdDurationInSeconds to allow for some fading
            NSNumber *startPsdFadingTime = @([self.psdDurationInSeconds doubleValue] - kPsdFadeOutTime);
            // Prepare stop and restart stream after the claimed lenght (minus kPsdFadeOutTime seconds to allow for fading)...
            if(self.thePsdTimer)
            {
                [self.thePsdTimer invalidate];
                self.thePsdTimer = nil;
            }
            DLog(@"We'll start PSD fading and prepare to stop after %@ secs", startPsdFadingTime);
            self.thePsdTimer = [NSTimer scheduledTimerWithTimeInterval:[startPsdFadingTime doubleValue] target:self selector:@selector(stopPsdFromTimer:) userInfo:nil repeats:NO];
            // start slow
            [self fadeInCurrentTrackNow:self.thePsdStreamer forSeconds:kFadeInTime];
            [self.thePsdStreamer play];
            DLog(@"Setting fade out after %@ sec for %.0f sec", startPsdFadingTime, kPsdFadeOutTime);
            [self presetFadeOutToCurrentTrack:self.thePsdStreamer startingAt:[startPsdFadingTime intValue] forSeconds:kPsdFadeOutTime];
            // Stop main streamer, remove observers and and reset timers it.
            [self unscheduleImagesTimer];
            if(self.isPSDPlaying)
            {
                // Fade out and quit previous stream
                [self fadeOutCurrentTrackNow:self.theOldPsdStreamer forSeconds:kPsdFadeOutTime];
                dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, kPsdFadeOutTime * NSEC_PER_SEC);
                dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                    DLog(@"Previous PSD stream now stopped!");
                    [self.theOldPsdStreamer pause];
                    self.theOldPsdStreamer = nil;
                });
            }
            else
            {
                // Quit main stream after fade-in of PSD
                self.isPSDPlaying = YES;
                dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, kFadeInTime * NSEC_PER_SEC);
                dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                    DLog(@"Main stream now stopped!");
                    [self.theStreamer pause];
                    [self.theStreamer removeObserver:self forKeyPath:@"status"];
                    self.theStreamer = nil;
                });
            }
            [self interfacePsd];
        }
        else if (self.thePsdStreamer.status == AVPlayerStatusFailed)
        {
            // something went wrong. player.error should contain some information
            DLog(@"Error starting PSD streamer: %@", self.thePsdStreamer.error);
            self.thePsdStreamer = nil;
            [self playMainStream];
        }
        else if (self.thePsdStreamer.status == AVPlayerStatusUnknown)
        {
            // something went wrong. player.error should contain some information
            DLog(@"AVPlayerStatusUnknown");
        }
        else
        {
            DLog(@"Unknown status received: %d", self.thePsdStreamer.status);
        }
    }
    else if(object == self.theStreamer && [keyPath isEqualToString:@"status"])
    {
        if (self.theStreamer.status == AVPlayerStatusFailed)
        {
            // something went wrong. player.error should contain some information
            DLog(@"Error starting the main streamer: %@", self.thePsdStreamer.error);
            self.theStreamer = nil;
            [self playMainStream];
        }
        else if (self.theStreamer.status == AVPlayerStatusReadyToPlay)

        {
            DLog(@"Stream is connected.");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self interfacePlay];
            });
        }
        else
        {
            DLog(@"Unknown status received: %d", self.thePsdStreamer.status);
        }
    }
    else
    {
        DLog(@"Something else called observeValueForKeyPath. KeyPath is %@", keyPath);
    }
}

- (void)playPSDNow
{
    DLog(@"playPSDNow called. Cookie is <%@>", self.cookieString);
    [self interfacePsdPending];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://www.radioparadise.com/ajax_replace.php?option=0"]];
    [req addValue:self.cookieString forHTTPHeaderField:@"Cookie"];
    [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
     {
         if(data)
         {
             NSString *retValue = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
             retValue = [retValue stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
             NSArray *values = [retValue componentsSeparatedByString:@"|"];
             if([values count] != 4)
             {
                 NSLog(@"ERROR: too many values (%d) returned from ajax_replace", [values count]);
                 NSLog(@"retValue: <%@>", retValue);
                 [self playMainStream];
                 return;
             }
             NSString *psdSongUrl = [values objectAtIndex:0];
             NSNumber *psdSongLenght = [values objectAtIndex:1];
             NSNumber * __unused psdSongFadeIn = [values objectAtIndex:2];
             NSNumber * __unused psdSongFadeOut = [values objectAtIndex:3];
             DLog(@"Got PSD song information: <%@>, should run for %@ ms, with fade-in, fade-out for %@ and %@", psdSongUrl, psdSongLenght, psdSongFadeIn, psdSongFadeOut);
             [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"PSD triggered"];
             // reset stream on main thread
             dispatch_async(dispatch_get_main_queue(), ^{
                 // If PSD is already running...
                 if(self.isPSDPlaying)
                 {
                     self.theOldPsdStreamer = self.thePsdStreamer;
                     [self.thePsdStreamer removeObserver:self forKeyPath:@"status"];
                 }
                 // Begin buffering...
                 self.thePsdStreamer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:psdSongUrl]];
                 // Add observer for real start and stop.
                 self.psdDurationInSeconds = @(([psdSongLenght doubleValue] / 1000.0));
                 [self.thePsdStreamer addObserver:self forKeyPath:@"status" options:0 context:nil];
             });
         }
         else // we have an error in PSD processing, (re)start main stream)
         {
             [self playMainStream];
         }
     }];
}

- (void)stopPressed:(id)sender
{
    if(self.isPSDPlaying)
    {
        // If PSD is running, simply get back to the main stream by firing the end timer...
        DLog(@"Manually firing the PSD timer (starting fading now)");
        [self fadeOutCurrentTrackNow:self.thePsdStreamer forSeconds:kPsdFadeOutTime];
        [self.thePsdTimer fire];
    }
    else
    {
        [self interfaceStopPending];
        [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"Stop"];
        // Process stop request.
        [self.theStreamer pause];
        // Let's give the stream a couple seconds to really stop itself
        double delayInSeconds = 1.0;    //was 2.0: MONITOR!
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self removeNotifications];
            [self unscheduleImagesTimer];
            self.theStreamer = nil;
            [self interfaceStop];
            // if called from bitrateChanged, restart
            if(sender == self)
                [self playMainStream];
        });
    }
}

- (IBAction)playOrStop:(id)sender
{
    if(self.theStreamer.rate != 0.0 || self.isPSDPlaying)
        [self stopPressed:nil];
    else
        [self playMainStream];
}

- (IBAction)bitrateChanged:(id)sender 
{
    switch (((UISegmentedControl *)sender).selectedSegmentIndex) 
    {
        case 0:
            self.theRedirector = kRPURL24K;
            [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"24K selected"];
            break;
        case 1:
            self.theRedirector = kRPURL64K;
            [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"64K selected"];
            break;
        case 2:
            self.theRedirector = kRPURL128K;
            [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"128K selected"];
            break;
        default:
            break;
    }
    // If needed, stop the stream
    if(self.theStreamer.rate != 0.0)
        [self stopPressed:self];
}

- (IBAction)startPSD:(id)sender
{
    // Try to understand if we have cookie string in KeyChain
    NSError *err;
    self.cookieString = [STKeychain getPasswordForUsername:@"cookies" andServiceName:@"RP" error:&err];
    if(self.cookieString)
    {
        [self playPSDNow];
        return;
    }
    if(self.cookieString != nil)
    {   // already logged in. no need to show the login box
        [self playPSDNow];
    }
    else
    {
        // Init controller and set ourself for callback
        RPLoginController * theLoginBox = [[RPLoginController alloc] initWithNibName:@"RPLoginController" bundle:[NSBundle mainBundle]];
        theLoginBox.delegate = self;
        // if iPad, embed in a popover, go modal for iPhone
        if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        {
            if(self.theLoginBox == nil)
                self.theLoginBox = [[UIPopoverController alloc] initWithContentViewController:theLoginBox];
            self.theLoginBox.popoverContentSize = CGSizeMake(320, 207);
            [self.theLoginBox presentPopoverFromRect:self.psdButton.frame inView:self.view permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
        }
        else
        {
            theLoginBox.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:theLoginBox animated:YES completion:nil];
        }
        // Release...
        theLoginBox = nil;
    }
}

- (IBAction)debugFadeIn:(id)sender
{
    [self fadeInCurrentTrackNow:(self.isPSDPlaying) ? self.thePsdStreamer : self.theStreamer forSeconds:3];
}

- (IBAction)debugFadeOut:(id)sender
{
    [self fadeOutCurrentTrackNow:(self.isPSDPlaying) ? self.thePsdStreamer : self.theStreamer forSeconds:3];
}

- (void)RPLoginControllerDidCancel:(RPLoginController *)controller
{
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone)
        [controller dismissModalViewControllerAnimated:YES];
}

- (void)RPLoginControllerDidSelect:(RPLoginController *)controller withCookies:(NSString *)cookiesString
{
    // dismiss the popover (if needed)
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
    {
        if([self.theLoginBox isPopoverVisible])
            [self.theLoginBox dismissPopoverAnimated:YES];
    }
    else // iPhone
        [controller dismissModalViewControllerAnimated:YES];
    self.cookieString = cookiesString;
    [self playPSDNow];
}

- (IBAction)showSongsList:(id)sender
{
    SongsViewController *theSongsBox = [[SongsViewController alloc] initWithNibName:@"SongsViewController" bundle:[NSBundle mainBundle]];
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        theSongsBox.modalPresentationStyle = UIModalPresentationPageSheet;
    else
        theSongsBox.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:theSongsBox animated:YES completion:nil];
    theSongsBox = nil;
}

- (IBAction)addCurrentSong:(id)sender
{
    // Recover song data...
    NSArray *songPieces = [self.metadataInfo.text componentsSeparatedByString:@" - "];
    if([songPieces count] == 2)
    {
        self.addSongButton.enabled = NO;
        // No save for RP metadata filler
        if([[songPieces objectAtIndex:0] isEqualToString:@"Commercial-free"])
            return;
        SongAdder *theAdder = [[SongAdder alloc] initWithTitle:[songPieces objectAtIndex:1] andArtist:[songPieces objectAtIndex:0] andCoversheet:self.coverImage];
        NSError *err;
        if(![theAdder addSong:&err])
        {
            // An error occurred when saving...
            NSString *temp = [NSString stringWithFormat:@"While saving the song got the error %@, %@", err, [err userInfo]];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error" message:temp delegate:nil cancelButtonTitle:@"Cancel" otherButtonTitles: nil];
            [alert show];
            self.addSongButton.enabled = YES;
        }
    }
    else
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error" message:@"Malformed song name, cannot save it." delegate:nil cancelButtonTitle:@"Cancel" otherButtonTitles: nil];
        [alert show];        
    }
}


- (IBAction)presentAboutBox:(id)sender
{
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
    {
        if(self.theAboutBox == nil)
        {
            self.theAboutBox = [[UIPopoverController alloc] initWithContentViewController:[[RPAboutBox alloc] initWithNibName:@"AboutBox" bundle:[NSBundle mainBundle]]];
            self.theAboutBox.popoverContentSize = CGSizeMake(340, 383);
        }
        [self.theAboutBox presentPopoverFromRect:self.aboutButton.frame inView:self.view permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
    }
    else
    {
        RPAboutBox *theAboutBox;
        if(self.theAboutBox == nil)
        {
            theAboutBox = [[RPAboutBox alloc] initWithNibName:@"AboutBox" bundle:[NSBundle mainBundle]];
            theAboutBox.modalPresentationStyle = UIModalPresentationFullScreen;
        }
        [self presentViewController:theAboutBox animated:YES completion:nil];
        theAboutBox = nil;
    }
}

- (IBAction)presentRPWeb:(id)sender 
{
    if(self.theWebView == nil)
    {
        self.theWebView = [[RPForumView alloc] initWithNibName:@"RPForumView" bundle:[NSBundle mainBundle]];
        if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
            self.theWebView.modalPresentationStyle = UIModalPresentationPageSheet;
        else
            self.theWebView.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    if(self.isPSDPlaying)
        self.theWebView.songId = self.psdSongId;
    else
        self.theWebView.songId = @"now";
    [self presentViewController:self.theWebView animated:YES completion:nil];
    self.theWebView = nil;
}

- (IBAction)songNameOverlayButton:(id)sender 
{
    [self presentRPWeb:sender];
}

#pragma mark -
#pragma mark Interface setup

-(void)activateNotifications
{
    DLog(@"*** activateNotifications");
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tvExternalScreenInited:) name:kTVInited object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationChangedState:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationChangedState:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self.theStreamer addObserver:self forKeyPath:@"status" options:0 context:nil];
}

-(void)removeNotifications
{
    DLog(@"*** removeNotifications");
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kTVInited object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self.theStreamer removeObserver:self forKeyPath:@"status"];
}

-(void)interfaceStop
{
    DLog(@"*** interfaceStop");
    if(self.interfaceState == kInterfaceMinimized || self.interfaceState == kInterfaceZoomed)
        [self interfaceToNormal];
    self.metadataInfo.text = @"";
    self.psdButton.enabled = YES;
    self.bitrateSelector.enabled = YES;
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-play"] forState:UIControlStateNormal];
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-play"] forState:UIControlStateHighlighted];
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-play"] forState:UIControlStateSelected];
    self.playOrStopButton.enabled = YES;
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd"] forState:UIControlStateNormal];
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd"] forState:UIControlStateHighlighted];
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd"] forState:UIControlStateSelected];
    self.psdButton.enabled = YES;
    [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateNormal];
    [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateHighlighted];
    [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateSelected];
    ((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).windowTV.hidden = YES;
    self.hdImage.hidden = YES;
    self.rpWebButton.hidden = YES;
    self.rpWebButton.enabled = NO;
    self.minimizerButton.enabled = NO;
    self.addSongButton.enabled = NO;
    if(self.theStreamMetadataTimer != nil)
    {
        [self.theStreamMetadataTimer invalidate];
        self.theStreamMetadataTimer = nil;
    }
    [self.spinner stopAnimating];
}

-(void)interfaceStopPending
{
    DLog(@"*** interfaceStopPending");
    [self.spinner startAnimating];
    if(self.interfaceState == kInterfaceMinimized || self.interfaceState == kInterfaceZoomed)
        [self interfaceToNormal];
    self.playOrStopButton.enabled = NO;
    self.bitrateSelector.enabled = NO;
    self.psdButton.enabled = NO;
    self.rpWebButton.enabled = NO;
    self.minimizerButton.enabled = NO;
    self.addSongButton.enabled = NO;
}

-(void)interfacePlay
{
    DLog(@"*** interfacePlay");
    self.bitrateSelector.enabled = YES;
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-stop"] forState:UIControlStateNormal];
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-stop"] forState:UIControlStateHighlighted];
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-stop"] forState:UIControlStateSelected];
    self.playOrStopButton.enabled = YES;
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd"] forState:UIControlStateNormal];
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd"] forState:UIControlStateHighlighted];
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd"] forState:UIControlStateSelected];
    self.psdButton.enabled = YES;
    self.minimizerButton.enabled = YES;
    ((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).windowTV.hidden = NO;
    self.rpWebButton.hidden = NO;
    self.rpWebButton.enabled = YES;
    self.addSongButton.enabled = YES;
    self.hdImage.hidden = NO;
    [self.spinner stopAnimating];
    // Only if the app is active, if this is called via events there's no need to load images
    if([UIApplication sharedApplication].applicationState == UIApplicationStateActive)
        [self scheduleImagesTimer];
    // Start metadata reading.
    DLog(@"Starting metadata handler...");
    [self metatadaHandler:nil];
}

-(void)interfacePlayPending
{
    DLog(@"*** interfacePlayPending");
    [self.spinner startAnimating];
    self.playOrStopButton.enabled = NO;
    self.bitrateSelector.enabled = NO;
    self.psdButton.enabled = NO;
    self.rpWebButton.enabled = NO;
    self.rpWebButton.hidden = NO;
    self.minimizerButton.enabled = NO;
    self.addSongButton.enabled = NO;
    self.hdImage.hidden = NO;
}

-(void)interfacePsd
{
    DLog(@"*** interfacePsd");
    self.psdButton.enabled = YES;
    self.bitrateSelector.enabled = NO;
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-left"] forState:UIControlStateNormal];
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-left"] forState:UIControlStateHighlighted];
    [self.playOrStopButton setImage:[UIImage imageNamed:@"button-left"] forState:UIControlStateSelected];
    self.playOrStopButton.enabled = YES;
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd-active"] forState:UIControlStateNormal];
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd-active"] forState:UIControlStateHighlighted];
    [self.psdButton setImage:[UIImage imageNamed:@"button-psd-active"] forState:UIControlStateSelected];
    self.psdButton.enabled = YES;
    self.addSongButton.enabled = YES;
    self.rpWebButton.enabled = YES;
    self.rpWebButton.hidden = NO;
    self.minimizerButton.enabled = YES;
    self.hdImage.hidden = NO;
    ((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).windowTV.hidden = NO;
    [self.spinner stopAnimating];
    // Only if the app is active, if this is called via events there's no need to load images
    if([UIApplication sharedApplication].applicationState == UIApplicationStateActive)
        [self scheduleImagesTimer];
    DLog(@"Getting PSD metadata...");
    [self metatadaHandler:nil];
}

-(void)interfacePsdPending
{
    DLog(@"*** interfacePsdPending");
    [self.spinner startAnimating];
    self.playOrStopButton.enabled = NO;
    self.bitrateSelector.enabled = NO;
    self.psdButton.enabled = NO;
    self.rpWebButton.enabled = NO;
    self.rpWebButton.hidden = NO;
    self.minimizerButton.enabled = NO;
    self.addSongButton.enabled = NO;
    self.hdImage.hidden = NO;
}

-(void)initializeIPhoneInterface
{
    // Nothing to do for iPads
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        return;
    BOOL isTallerScreen = ([UIScreen mainScreen].bounds.size.height == 568.0f);
    if(isTallerScreen)
    {
        DLog(@"This is an iPhone5 display, setup it!");
        self.addSongButton.frame = CGRectMake(34, 278, 36, 36);
        self.iPhoneLogoImage.frame = CGRectMake(9, 9, 40, 40);
        self.metadataInfo.frame = CGRectMake(98, 16, 450, 21);
        self.songNameButton.frame = CGRectMake(98, 16, 450, 21);
        self.minimizerButton.frame = CGRectMake(0, 0, 568, 320);
        self.hdImage.frame = CGRectMake(0, 0, 568, 320);
        self.playOrStopButton.frame = CGRectMake(512, 278, 36, 36);
        self.volumeViewContainer.frame = CGRectMake(324, 283, 180, 25);
        self.songListButton.frame = CGRectMake(280, 278, 36, 36);
        self.psdButton.frame = CGRectMake(236, 278, 36, 36);
        self.bitrateSelector.frame = CGRectMake(77, 281, 151, 30);
        self.spinner.frame = CGRectMake(266, 116, 37, 37);
    }
}

- (void) interfaceToMinimized
{
    [UIView animateWithDuration:0.5 
                     animations:^(void) {
                         self.aboutButton.alpha = self.bitrateSelector.alpha = self.rpWebButton.alpha = self.volumeViewContainer.alpha = self.separatorImage.alpha = 0.0;
                         if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone)
                             self.psdButton.alpha = self.songListButton.alpha = 0.0;
                         if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
                         {
                             self.hdImage.frame = CGRectMake(2, 97, 1020, 574);
                             self.minimizerButton.frame = CGRectMake(2, 97, 1020, 574);
                             self.metadataInfo.frame = CGRectMake(174, 707, 830, 21);
                             self.songNameButton.frame = CGRectMake(504, 707, 500, 21);
                             self.playOrStopButton.frame = CGRectMake(10, 695, 43, 43);
                             self.addSongButton.frame = CGRectMake(150, 695, 43, 43);
                             self.songListButton.frame = CGRectMake(220, 695, 43, 43);
                             self.separatorImage.frame = CGRectMake(0, 672, 1024, 23);
                             self.psdButton.frame = CGRectMake(80, 695, 43, 43);
                             self.logoImage.frame = CGRectMake(20, 2, 300, 94);
                         }
                         else
                         {
                             if([UIScreen mainScreen].bounds.size.height == 568.0f)
                             { // iPhone 5
                                 self.hdImage.frame = CGRectMake(0, 0, 568, 320);
                                 self.minimizerButton.frame = CGRectMake(0, 0, 568, 320);
                                 self.metadataInfo.frame = CGRectMake(109, 3, 450, 21);
                                 self.songNameButton.frame = CGRectMake(98, 2, 450, 21);
                                 self.playOrStopButton.frame = CGRectMake(539, 290, 25, 25);
                                 self.addSongButton.frame = CGRectMake(5, 290, 25, 25);
                                 self.iPhoneLogoImage.frame = CGRectMake(4, 1, 25, 25);
                             }
                             else
                             { // "normal" iPhone
                                 self.hdImage.frame = CGRectMake(0, 25, 480, 270);
                                 self.minimizerButton.frame = CGRectMake(0, 25, 480, 270);
                                 self.metadataInfo.frame = CGRectMake(98, 2, 373, 21);
                                 self.songNameButton.frame = CGRectMake(98, 2, 373, 21);
                                 self.playOrStopButton.frame = CGRectMake(446, 295, 25, 25);
                                 self.addSongButton.frame = CGRectMake(9, 295, 25, 25);
                                 self.iPhoneLogoImage.frame = CGRectMake(9, 0, 25, 25);
                             }
                         }
                     }
                     completion:^(BOOL finished) {
                         self.aboutButton.hidden = self.bitrateSelector.hidden = self.rpWebButton.hidden = self.volumeViewContainer.hidden = self.separatorImage.hidden = YES;
                         self.interfaceState = kInterfaceMinimized;
                     }];
}

- (void) interfaceToNormal
{
    self.aboutButton.hidden = self.logoImage.hidden = self.bitrateSelector.hidden = self.rpWebButton.hidden = self.volumeViewContainer.hidden = self.separatorImage.hidden = NO;
    [UIView animateWithDuration:0.5
                     animations:^(void) {
                         self.aboutButton.alpha = self.logoImage.alpha = self.bitrateSelector.alpha = self.songListButton.alpha = self.rpWebButton.alpha = self.volumeViewContainer.alpha = self.separatorImage.alpha = 1.0;
                         if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone)
                             self.psdButton.alpha = self.songListButton.alpha = 1.0;
                         if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
                         {
                             self.hdImage.frame = CGRectMake(2, 2, 1020, 574);
                             self.minimizerButton.frame = CGRectMake(2, 2, 1020, 574);
                             self.metadataInfo.frame = CGRectMake(23, 605, 830, 21);
                             self.songNameButton.frame = CGRectMake(353, 605, 500, 21);
                             self.playOrStopButton.frame = CGRectMake(350, 634, 43, 43);
                             self.addSongButton.frame = CGRectMake(440, 634, 43, 43);
                             self.songListButton.frame = CGRectMake(485, 686, 43, 43);
                             self.separatorImage.frame = CGRectMake(0, 577, 1024, 23);
                             self.psdButton.frame = CGRectMake(395, 686, 43, 43);
                             self.logoImage.frame = CGRectMake(20, 626, 300, 94);
                         }
                         else
                         {
                             if([UIScreen mainScreen].bounds.size.height == 568.0f)
                             { // iPhone 5
                                 self.hdImage.frame = CGRectMake(0, 0, 568, 320);
                                 self.minimizerButton.frame = CGRectMake(0, 0, 568, 320);
                                 self.metadataInfo.frame = CGRectMake(98, 16, 450, 21);

                                 self.songNameButton.frame = CGRectMake(98, 16, 450, 21);
                                 self.playOrStopButton.frame = CGRectMake(512, 278, 36, 36);
                             }
                             else
                             { // "normal" iPhone
                                 self.hdImage.frame = CGRectMake(0, 0, 480, 270);
                                 self.minimizerButton.frame = CGRectMake(0, 0, 480, 270);
                                 self.metadataInfo.frame = CGRectMake(98, 16, 373, 21);
                                 self.songNameButton.frame = CGRectMake(98, 16, 373, 21);
                                 self.playOrStopButton.frame = CGRectMake(435, 278, 36, 36);
                             }
                             // in any case...
                             self.addSongButton.frame = CGRectMake(34, 278, 36, 36);
                             self.iPhoneLogoImage.frame = CGRectMake(9, 9, 40, 40);
                         }
                         
                     }
                     completion:^(BOOL finished) {
                         self.interfaceState = kInterfaceNormal;
                     }];
}

- (void)interfaceToZoomed
{
    [UIView animateWithDuration:0.5 
                     animations:^(void) {
                         self.aboutButton.alpha = self.logoImage.alpha = self.bitrateSelector.alpha = self.rpWebButton.alpha = self.volumeViewContainer.alpha = self.separatorImage.alpha = 0.0;
                         // 574 : 768 = 1020 : x -> x = 1020 * 768 / 574
                         self.hdImage.frame = CGRectMake(-170, 0, 1364, 768);
                         self.minimizerButton.frame = CGRectMake(-170, 0, 1364, 768);
                         self.metadataInfo.frame = CGRectMake(174, 707, 830, 21);
                         self.songNameButton.frame = CGRectMake(504, 707, 500, 21);
                         self.playOrStopButton.frame = CGRectMake(10, 695, 43, 43);
                         self.separatorImage.frame = CGRectMake(0, 672, 1024, 23);
                         self.psdButton.frame = CGRectMake(80, 695, 43, 43);
                    }
                     completion:^(BOOL finished) {
                         self.aboutButton.hidden = self.logoImage.hidden = self.bitrateSelector.hidden = self.rpWebButton.hidden = self.volumeViewContainer.hidden = self.separatorImage.hidden = YES;
                         self.logoImage.frame = CGRectMake(20, 626, 300, 94);
                         self.interfaceState = kInterfaceZoomed;
                     }];    
}

- (IBAction)minimizer:(id)sender 
{
    switch (self.interfaceState) {
        case kInterfaceNormal:
            [self interfaceToMinimized];
            break;
        case kInterfaceMinimized:
            if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
                [self interfaceToZoomed];
            else
                [self interfaceToNormal];
            break;
        case kInterfaceZoomed:
            [self interfaceToNormal];
        default:
            DLog(@"minimizer called with self.interfaceState to %d", self.interfaceState);
            break;
    }
}

#pragma mark -
#pragma mark LoadUnload

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
    // reset text
    self.metadataInfo.text = @"";
    self.rpWebButton.hidden = YES;
    self.theRedirector = kRPURL64K;
    // Detect iPhone 5
    [self initializeIPhoneInterface];
    // Add the volume (fake it on simulator)
    self.volumeViewContainer.backgroundColor = [UIColor clearColor];
    if (!TARGET_IPHONE_SIMULATOR)
    {
        MPVolumeView *myVolumeView = [[MPVolumeView alloc] initWithFrame:self.volumeViewContainer.bounds];
        [self.volumeViewContainer addSubview: myVolumeView];
        myVolumeView = nil;
    }
    else
    {
        UISlider *myVolumeView = [[UISlider alloc] initWithFrame:self.volumeViewContainer.bounds];
        myVolumeView.value = 0.5;
        [self.volumeViewContainer addSubview: myVolumeView];
        myVolumeView = nil;
    }
    // Prepare for background audio
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    [[AVAudioSession sharedInstance] setActive: YES error: nil];
    [[AVAudioSession sharedInstance] setDelegate:self];

    self.imageLoadQueue = [[NSOperationQueue alloc] init];
    self.interfaceState = kInterfaceNormal;
    self.minimizerButton.enabled = NO;
    // Set PSD to not logged, not playing
    self.cookieString = nil;
    self.isPSDPlaying = NO;
    // set bounds and corners
    self.hdImage.layer.cornerRadius = 8.0;
    self.hdImage.clipsToBounds = YES;
    self.rpWebButton.layer.cornerRadius = 4.0;
    self.rpWebButton.clipsToBounds = YES;
    // Automagically start, as per bg request
    [self playMainStream];
    // We would like to receive starts and stops
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    [self becomeFirstResponder];
    // Give a touch to the UI after a while (only on iPhone 5). This is a terrible hack, I know.
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone && [UIScreen mainScreen].bounds.size.height == 568.0f)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^(void){
            [self interfaceToNormal];
        });
    }
}

- (void)viewDidUnload
{
    [self setMetadataInfo:nil];
    [self setSpinner:nil];
    [self setVolumeViewContainer:nil];
    [self.imageLoadQueue cancelAllOperations];
    [self setImageLoadQueue:nil];
    [self setPlayOrStopButton:nil];
    [self setHdImage:nil];
    [self setAboutButton:nil];
    [self setRpWebButton:nil];
    [self setMinimizerButton:nil];
    [self setLogoImage:nil];
    [self setBitrateSelector:nil];
    [self setSongNameButton:nil];
    [self setSeparatorImage:nil];
    [self setIPhoneLogoImage:nil];
    [self setPsdButton:nil];
    [self setThePsdStreamer:nil];
    [self setTheOldPsdStreamer:nil];
    [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
    [self resignFirstResponder];
    [[AVAudioSession sharedInstance] setDelegate:nil];
    [self setAddSongButton:nil];
    [self setSongListButton:nil];
    [super viewDidUnload];
}

#pragma mark -
#pragma mark Multimedia and Remote Control

// If interrupted by a call, set interface to stop (user will restart if willing to)
- (void)beginInterruption
{
    // Process stop request.
    DLog(@"This is the beginInterruption handler");
    [self unscheduleImagesTimer];
    if(self.isPSDPlaying)
    {
        self.isPSDPlaying = NO;
        if(self.thePsdTimer)
        {
            [self.thePsdTimer invalidate];
            self.thePsdTimer = nil;
        }
        [self.thePsdStreamer removeObserver:self forKeyPath:@"status"];
        self.thePsdStreamer = nil;
    }
    else
    {
        [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"Stop"];
        [self removeNotifications];
        self.theStreamer = nil;
        [self interfaceStop];
    }
    if(self.theStreamer.rate != 0.0  || self.isPSDPlaying)
        [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"Play interrupted by call or event"];
    // In any case (also if not playing stop localytics
    [[LocalyticsSession sharedLocalyticsSession] close];
    [[LocalyticsSession sharedLocalyticsSession] upload];
}

-(void)applicationChangedState:(NSNotification *)note
{
    DLog(@"applicationChangedState: %@", note.name);
    if([note.name isEqualToString:UIApplicationDidEnterBackgroundNotification])
        dispatch_async(dispatch_get_main_queue(), ^{
            // If backgrounding during play, don't quit Localytics session
            if(self.theStreamer.rate != 0.0 || self.isPSDPlaying)
            {
                [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"Backgrounding while playing"];
                [[LocalyticsSession sharedLocalyticsSession] upload];
            }
            else
            {
                [[LocalyticsSession sharedLocalyticsSession] close];
                [[LocalyticsSession sharedLocalyticsSession] upload];
            }
            // If we don't have a second screen...
            if ([[UIScreen screens] count] == 1)
            {
                DLog(@"No more images, please");
                [self unscheduleImagesTimer];
            }
            // We would like to receive starts and stops
            [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
            [self becomeFirstResponder];
        });
    if([note.name isEqualToString:UIApplicationWillEnterForegroundNotification])
        dispatch_async(dispatch_get_main_queue(), ^{
            if(self.theStreamer.rate != 0.0  || self.isPSDPlaying)
            {
                [[LocalyticsSession sharedLocalyticsSession] tagEvent:@"In Foreground while Playing"];
                // If we don't have a second screen (else the timer was not stopped
                if ([[UIScreen screens] count] == 1)
                {
                    DLog(@"Images again, please");
                    [self scheduleImagesTimer];
                }
            }
            else
            {
                [[LocalyticsSession sharedLocalyticsSession] resume];
                [[LocalyticsSession sharedLocalyticsSession] upload];                
            }
            [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
            [self resignFirstResponder];
        });
}

- (void) remoteControlReceivedWithEvent: (UIEvent *) receivedEvent
{
    DLog(@"Remote control received");
    if (receivedEvent.type == UIEventTypeRemoteControl) {
        switch (receivedEvent.subtype) 
        {
            case UIEventSubtypeRemoteControlTogglePlayPause:
                [[LocalyticsSession sharedLocalyticsSession] close];
                [[LocalyticsSession sharedLocalyticsSession] upload];
                [self playOrStop: nil];
                break;
            case UIEventSubtypeRemoteControlPreviousTrack:
                break;
            case UIEventSubtypeRemoteControlNextTrack:
                // Start PSD on "next track" request
                [self startPSD:nil];
                break;
            default:
                break;
        }
    }
}

- (BOOL) canBecomeFirstResponder 
{
    return YES;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    DLog(@"shouldAutorotateToInterfaceOrientation called for mainController");
    if((interfaceOrientation == UIInterfaceOrientationLandscapeLeft) || (interfaceOrientation == UIInterfaceOrientationLandscapeRight))
        return YES;
    else
        return NO;
}

@end
