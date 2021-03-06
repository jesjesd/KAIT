﻿using KAIT.EventHub.Messaging;
using KAIT.Common.Services.Communication;
using KAIT.Common.Services.Messages;
using System;
using System.Collections.Generic;
using System.Configuration;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using KAIT.Common.Interfaces;
using GalaSoft.MvvmLight.Ioc;
using Microsoft.ProjectOxford.Face.Contract;

//using System.Windows.Media.Imaging;

namespace KAIT.Biometric.Services
{
    public class OxfordBiometricTelemetryService : IDemographicsService
    {

        public event EventHandler<BiometricData> PlayerIdentified;

        public event EventHandler<string> DemographicsProcessingFailure;

        public event EventHandler<BiometricData> DemographicsReceived;

        private Thread _lostTrackingPolling;

       
        private ITelemetryService _dataBroker;
        private int _overSamplingThreshold = 1;
        private bool _IsNECInFaultCondition = false;

        private bool _shutdown = false;

        private EventHubMessageSender _eventHub;

        List<UserExperienceContext> _userExperiences = new List<UserExperienceContext>();

        bool _cloudConnectionFailure = false;

        public bool TestMode { get; set; }

        public bool DebugImages { get; set; }

        public bool IsPrimaryRoleBiometricID = false;

        public bool IsStickySessionEnabled = false;


        protected virtual void OnDemographicsProcessingFailure(string e)
        {
            // Note the use of a temporary variable here to make the event raisin
            // thread-safe; may or may not be necessary in your case.
            var evt = this.DemographicsProcessingFailure;
            if (evt != null)
                evt(this, e);
        }

        protected virtual void OnPlayerIdentified(BiometricData e)
        {
            // Note the use of a temporary variable here to make the event raisin
            // thread-safe; may or may not be necessary in your case.
            var evt = this.PlayerIdentified;
            if (evt != null)
                evt(this, e);
        }
        
        public OxfordBiometricTelemetryService(string EventHubConnectionString)
        {
            _eventHub = new EventHubMessageSender(EventHubConnectionString);

            ConfigureOverSampling();
            
            Init();
        }

        private void ConfigureOverSampling()
        {
            _overSamplingThreshold = System.Convert.ToInt32(ConfigurationManager.AppSettings["BiometricTelemetryService.OverSamplingThreshold"]);

            if (_overSamplingThreshold == 0)
                _overSamplingThreshold = 1;
        }
        [PreferredConstructorAttribute]
        public OxfordBiometricTelemetryService()
        {
            ConfigureOverSampling();
        }
        
        public string EventHubConnectionString
        {
            set
            {
                if(!string.IsNullOrEmpty(value))
                    _eventHub = new EventHubMessageSender(value);

            }
        }
        private async void Init()
        { 
            _lostTrackingPolling = new Thread(this.UpdateAndPublishLostTracks);
            _lostTrackingPolling.Start();
        }

        public void Shutdown()
        {
            _shutdown = true;
        }
        private PlayerBiometrics _activePlayerBiometricData;

        private Dictionary<ulong, PlayerBiometrics> _playerBiometrics = new Dictionary<ulong,PlayerBiometrics>();

        public async Task ProcessFace(ProcessFaceData Sample)
        {
            ProcessFace(Sample.TrackingID, Sample.PlayersFace);
        }
        public async Task<bool> ProcessFace(ulong trackingId, Bitmap bitmap)
        {
            //check to see if we've already processed this play to qualification so we can short cut processing...
            //this will occur as this process is happening on a paralle thread and we could be behind
            if (!IsNewPlayer(trackingId))
            {
                Debug.Print("Bypassed: " + trackingId);
                return true;
            }

            System.Drawing.Bitmap bmp = bitmap;// CreateBitmap(trackingId, bitmap);
            String tempFile = @"c:\temp\file1.jpg";
            bmp.Save(tempFile, ImageFormat.Jpeg);
            var fileStream = File.OpenRead(tempFile);

            Debug.Print("------------------------------------------------------------------------------------------------Process Face ");

            try
            {

                Face[] faces;

                //if (DebugImages)
                //    bmp.Save("C:\\TEMP\\REJECTED\\" + trackingId + ".png", System.Drawing.Imaging.ImageFormat.Png);

                if (!TestMode)
                {
                    ImageAnalyzer analyzer = new ImageAnalyzer();
                    faces = await analyzer.AnalyzeImageUsingHelper(fileStream);
                }
                else
                {
                    faces = null;
                }


                Debug.Print("Evaluate Demographics ");                                              //Male                             //Female
                if (TestMode || (faces != null && faces.Length > 0)) 
                {
                    Debug.Print("Get Demographcis ");
                    var current = GetDemographics(trackingId, faces);

                    //TESTING
                    Debug.Print("Age = " + current.Age);
                    Debug.Print("Gender = " + current.Gender);

                    //This is implemented this way to maximize performance and avoid extra loops since it will only happen ONCE for every new user
                    try
                    {
                        _activePlayerBiometricData = _playerBiometrics[trackingId];
                    }
                    catch
                    {
                        _activePlayerBiometricData = null;
                    }

                    if (current != null)
                    {
                        // this should only occur if we are primarily in a Biometric authentication mode in which case we already processed  sensor reads to create the demographics profile.
                        // but there are some cases were we may still identify the user so we need to reset the profile is we suddenly recognize the person.
                        if (_activePlayerBiometricData != null
                            && IsPrimaryRoleBiometricID
                            && _activePlayerBiometricData.SamplingCount >= _overSamplingThreshold
                            && _activePlayerBiometricData.Transmitted) // && current.FaceMatch)
                        {
                            Debug.Print("Update base on Biometric Auth. Resetting profile " + current.TrackingId.ToString());
                            _activePlayerBiometricData.ResetBiometricSamples();
                            _activePlayerBiometricData.Transmitted = false;
                            _activePlayerBiometricData.Add(current);

                        }//Once we reach the sample threshold and we're not in a contiuation we transmit the data to the subscribers
                        else
                        {
                            if (_activePlayerBiometricData == null)
                            {
                                Debug.Print("Added New Player " + current.TrackingId.ToString() + " " + Thread.CurrentThread.ManagedThreadId);
                                _activePlayerBiometricData = new PlayerBiometrics(current);
                                _playerBiometrics.Add(_activePlayerBiometricData.TrackingID, _activePlayerBiometricData);
                            }
                            else if (_activePlayerBiometricData.SamplingCount < _overSamplingThreshold)
                            {
                                Debug.Print("Added New Sample " + current.TrackingId.ToString());
                                _activePlayerBiometricData.Add(current);


                            }

                            if (_activePlayerBiometricData.Transmitted == false
                                   && _activePlayerBiometricData.SamplingCount >= _overSamplingThreshold
                                   && !IsNewUserAContinuation(_activePlayerBiometricData))
                            {
                                Debug.Print("Returned Demographics " + current.TrackingId.ToString());

                                var PlaysTrueBiometrics = _activePlayerBiometricData.FilteredBiometricData;

                                PlaysTrueBiometrics.TrackingState = BiometricTrackingState.TrackingStarted;
                                PlaysTrueBiometrics.FaceImage = bmp;

                                RaiseDemographicsEvent(PlaysTrueBiometrics);

                                OnPlayerIdentified(PlaysTrueBiometrics);

                                _eventHub.SendMessageToEventHub(PlaysTrueBiometrics);

                                _activePlayerBiometricData.Transmitted = true;
                            }
                        }


                    }

                }
                else
                {
                    Debug.Print("Quality Issue Rejecting Image");
                    //if (DebugImages)
                    //    bmp.Save("C:\\TEMP\\REJECTED" + trackingId + ".png", System.Drawing.Imaging.ImageFormat.Png);
                }

                return true;
            }
            catch(Exception ex)
            {
                OnDemographicsProcessingFailure(ex.Message + " " + ex.InnerException);
                return false;
            }
        }

        //This method could be involked by the app hosting the kinect sensor when it looses track on a player. 
        //If its not called the Biometric service will eventaully realize it hasn't seen the player 
        //in a while and remove them.
        public void LostTrackingForPlayer(ulong TrackingID)
        {
            var lostPlayer = (from player in _playerBiometrics where player.Value.TrackingID == TrackingID select player).FirstOrDefault().Value;

            if (lostPlayer != null)
            {
                lostPlayer.ActivelyTracked = false;

                var playersBiometrics = lostPlayer.FilteredBiometricData;
                
                if (lostPlayer.FaceID == "")
                {
                    

                    playersBiometrics.TrackingState = BiometricTrackingState.TrackingLost;

                 
                   
                    

                    _playerBiometrics.Remove(lostPlayer.TrackingID);
                }

                OnPlayerIdentified(playersBiometrics);
            }
         

        }
        public bool IsNewPlayer(ulong TrackingID)
        {

            PlayerBiometrics activePlayerBiometricData;
            try
            { 
                activePlayerBiometricData = _playerBiometrics[TrackingID];// (from player in _playerBiometrics where player.TrackingID == TrackingID select player).FirstOrDefault();
            }
            catch
            {
                activePlayerBiometricData = null;
            }
           
            if (activePlayerBiometricData == null)
            {
                Debug.Print("IsNewPlayer: True " + TrackingID.ToString());
                return true;
            }                                                         //Set things so we continue to see if we can identify this player...
            else if (activePlayerBiometricData.SamplingCount < _overSamplingThreshold || (IsPrimaryRoleBiometricID && activePlayerBiometricData.FilteredBiometricData.FaceID == ""))
            {
                activePlayerBiometricData.LastSeen = DateTime.Now;
                Debug.Print("IsNewPlayer: Sample " + TrackingID.ToString());
                return true;
            }
            else
            {
                activePlayerBiometricData.LastSeen = DateTime.Now;
                var t = activePlayerBiometricData.FaceID;
                Debug.Print("IsNewPlayer: False " + TrackingID.ToString());
                return false;
            }
                
        }
        private bool IsNewUserAContinuation(PlayerBiometrics bioMetricData)
        {
            if (bioMetricData.FaceID != "")
            {
                var CheckList = from users in _playerBiometrics where users.Value.FaceID == bioMetricData.FaceID orderby users.Value.LastSeen select users;

                if (CheckList != null && CheckList.Count() > 1)
                {
                    var orginalRecord = CheckList.FirstOrDefault().Value;

                    var diff = DateTime.Now.Subtract(orginalRecord.LastSeen);


                    if (diff.Minutes == 0)
                    {
                        Debug.Print("I'VE SEEN YOU BEFORE " + orginalRecord.TrackingID.ToString() + " New ID " + bioMetricData.TrackingID.ToString());
                        _playerBiometrics.Remove(orginalRecord.TrackingID);
                        return true;
                    }
                    else
                    {
                        return false;
                    }
                }
                else
                {
                    return false;
                }
            }
            else
            {
                return false;
                
            }

        }

        Random _rnd = new Random();
        private BiometricData GetDemographics(ulong id, Face[] Results)
        {
            if (TestMode)
            {
                var confidence = _rnd.NextDouble();
                var result = new BiometricData()
                {
                    Age = _rnd.Next(10, 90),
                    Gender = (_rnd.NextDouble() <= 0.3) ? Gender.Male : Gender.Female,
                    GenderConfidence = (confidence < 0.5) ? 0.5 : confidence,
                    TrackingId = id
                };

                return result;
            }
            else
            {

                if (Results.Count() > 0)
                {
                    var demographic = new BiometricData();
                    demographic.TrackingId = id;
                    demographic.Age = Convert.ToInt32(Results[0].Attributes.Age);
                    demographic.Gender = Results[0].Attributes.Gender.ToUpper().Contains("F") ? Gender.Female : Gender.Male;
                    demographic.FaceID = Results[0].FaceId.ToString();
                    
                    return demographic;
                }
                else
                {
                    return null;
                }
            }

        }

      

        public void  UpdateAndPublishLostTracks()
        {

            do
            {
                //We only declare that we lost the individuals track if we haven't see in them in over 60 seconds. This is different than losing a skeletal track as
                //the biometrics services doesn't watch for sekelta tracks to be lost we're monitoring how long has it been since we saw the users face. If they don't look at the screen for 
                //more than 60 seconds we could lose their track even thought they're still present.
                var expiredTracks = (from users in _playerBiometrics where (DateTime.Now.Subtract(users.Value.LastSeen).Minutes > 0 ) select users.Value).ToArray();


                //we don't automatically publish a lost track when the sensor loses a players track in case its an intermitent loss
                foreach (PlayerBiometrics pbm in expiredTracks)
                {
                    if (DateTime.Now.Subtract(pbm.LastSeen).Minutes > 0)
                    {
                        var playersBiometrics = pbm.FilteredBiometricData;

                        playersBiometrics.TrackingState = BiometricTrackingState.TrackingLost;
       
                        
                        RaiseDemographicsEvent(playersBiometrics);
                 
                        _playerBiometrics.Remove(pbm.TrackingID);

                        if(!IsStickySessionEnabled)
                            _userExperiences.RemoveAll(x => x.TrackingId == pbm.TrackingID);

                    }

                }

                Thread.Sleep(1000);
            } while (!_shutdown);
        }

        /// <summary>

        /// Resize the image to the specified width and height.

        /// </summary>

        /// <param name="image">The image to resize.</param>

        /// <param name="width">The width to resize to.</param>

        /// <param name="height">The height to resize to.</param>

        /// <returns>The resized image.</returns>

        private static Bitmap ResizeImage(Image image, int width, int height)
        {

            var destRect = new Rectangle(0, 0, width, height);

            var destImage = new Bitmap(width, height);



            destImage.SetResolution(image.HorizontalResolution, image.VerticalResolution);



            using (var graphics = Graphics.FromImage(destImage))
            {

                graphics.CompositingMode = CompositingMode.SourceCopy;

                graphics.CompositingQuality = CompositingQuality.HighQuality;

                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;

                graphics.SmoothingMode = SmoothingMode.HighQuality;

                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;



                using (var wrapMode = new ImageAttributes())
                {

                    wrapMode.SetWrapMode(WrapMode.TileFlipXY);

                    graphics.DrawImage(image, destRect, 0, 0, image.Width, image.Height, GraphicsUnit.Pixel, wrapMode);

                }

            }



            return destImage;

        }

        private static async Task<Bitmap> EnhanceImage(Bitmap originalImage)
        {

            Bitmap adjustedImage = new Bitmap(originalImage);
            float brightness = 1.0f; // no change in brightness
            float contrast = 3.5f; // twice the contrast
            float gamma = 1.0f; // no change in gamma

            float adjustedBrightness = brightness - 1.0f;
            // create matrix that will brighten and contrast the image
            float[][] ptsArray ={
            new float[] {contrast, 0, 0, 0, 0}, // scale red
            new float[] {0, contrast, 0, 0, 0}, // scale green
            new float[] {0, 0, contrast, 0, 0}, // scale blue
            new float[] {0, 0, 0, 1.0f, 0}, // don't scale alpha
            new float[] {adjustedBrightness, adjustedBrightness, adjustedBrightness, 0, 1}};

            var imageAttributes = new ImageAttributes();
            imageAttributes.ClearColorMatrix();
            imageAttributes.SetColorMatrix(new ColorMatrix(ptsArray), ColorMatrixFlag.Default, ColorAdjustType.Bitmap);
            imageAttributes.SetGamma(gamma, ColorAdjustType.Bitmap);

            Graphics g = Graphics.FromImage(adjustedImage);
            g.DrawImage(originalImage, new Rectangle(0, 0, adjustedImage.Width, adjustedImage.Height)
                , 0, 0, originalImage.Width, originalImage.Height,
                GraphicsUnit.Pixel, imageAttributes);

          
            return adjustedImage;
        }

     
        private void RaiseDemographicsEvent(BiometricData payload)
        {
            var handler = this.DemographicsReceived;
            if (handler != null && payload != null)
            {
                handler(this, payload);

               
                    //This code is only for situations where you want the app to remember the user. It requires that we perform face recoginition
                    UserExperienceContext uec = new UserExperienceContext();
                    uec.Age = payload.Age;
                    uec.Gender = payload.Gender;
                    uec.FaceID = payload.FaceID;

                    uec.InteractionCount = 1;
                /*
                    if (payload.FaceMatch)
                    {
                        //Find out if we've already seen this person
                        var orginalUser = (from users in _userExperiences where users.FaceID == payload.FaceID select users).FirstOrDefault();

                        if (orginalUser == null)
                        {
                            uec.TrackingId = payload.TrackingId;
                            _userExperiences.Add(uec);
                        }
                        else
                        {
                            orginalUser.TrackingId = payload.TrackingId;
                            orginalUser.InteractionCount++;
                        }

                    }
                    else
                    {
                        uec.TrackingId = payload.TrackingId;
                        _userExperiences.Add(uec);
                    }
            */
            }
               
        }
        public void Listen(string source)
        {
           
        }

        public List<UserExperienceContext> UserExperiences
        {
            get { return _userExperiences; }
        }





        public void EnrollFace(string FaceID, Bitmap FaceImage)
        {
            //NEC.NeoFace.Engage.FaceAnalyser.EnrollFace(FaceID, FaceImage, ExtractionType.Both);
        }
    }

 
    public class PlayerBiometrics
    {
        ulong _trackingID;
        string _faceID;
        Gender _gender = Gender.Unknown;
        int _age = 0;

        //Is being tracked by the Kinect Sensor
        public bool ActivelyTracked = false;

        public bool Transmitted = false;
        public ulong TrackingID
        {
            get {
            //    LastSeen = DateTime.Now;
                 return _trackingID;
            }
            set { _trackingID = value; }
        }
        public string FaceID
        {
            get
            {
               
                return GetFaceID();
            }
        }
        public int SamplingCount
        {
            get { return _biometricDataSamples.Count; }
        }

        public DateTime LastSeen;

        public PlayerBiometrics(BiometricData Data)
        {
            LastSeen = DateTime.Now;
            this.ActivelyTracked = true;
            _biometricDataSamples = new List<BiometricData>();
            _biometricDataSamples.Add(Data);
            TrackingID = Data.TrackingId;
        }

        private List<BiometricData> _biometricDataSamples;

        public BiometricData FilteredBiometricData
        {
            get
            {
                var returnedData = new BiometricData();
                returnedData = _biometricDataSamples[0];
                returnedData.FaceID = GetFaceID();
                returnedData.Age = GetAge();
                returnedData.Gender = GetGender();

                return returnedData;
            }
            private set
            {

            }
        }

        public void Add(BiometricData BiometricSample)
        {
            LastSeen = DateTime.Now;
            this.ActivelyTracked = true;
            _biometricDataSamples.Add(BiometricSample);
        }

        public void ResetBiometricSamples()
        {
            _biometricDataSamples.Clear();
        }

        private string GetFaceID()
        {
            Dictionary<string, int> FaceIDs = new Dictionary<string, int>();
            foreach (BiometricData bod in _biometricDataSamples)
            {
                if(FaceIDs.ContainsKey(bod.FaceID + ""))
                {
                    FaceIDs[bod.FaceID + ""]++;
                }
                else
                {
                    FaceIDs.Add(bod.FaceID +"", 1);
                    
                }

            }

            var results = (from ids in FaceIDs orderby ids.Value descending select ids).FirstOrDefault();

            return results.Key;
        }

        private int GetAge()
        {
            if(_age == 0)
                _age = (from data in _biometricDataSamples orderby data.Age descending select data.Age).FirstOrDefault();

            return _age;
        }

        private Gender GetGender()
        {
            if (_gender == Gender.Unknown)
                _gender = (from data in _biometricDataSamples orderby data.Age descending select data.Gender).FirstOrDefault();
            return _gender;
        }

    }

    public class ProcessFaceData
    {
       public Bitmap PlayersFace { get; set; }
       public ulong TrackingID { get; set; }
    }
}
