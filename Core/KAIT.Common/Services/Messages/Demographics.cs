﻿namespace KAIT.Common.Services.Messages
{  
    public class DemographicData : IDemographicData
    {
        public ulong TrackingId { get; set; }
        public Gender Gender { get; set; }
        public int Age { get; set; }

        public double GenderConfidence { get; set; }

        public ulong FaceID { get; set; }

        public bool FaceMatch { get; set; }

        public float FaceConfidence { get; set; }

        public float FaceScore { get; set; }

        public float FrontalFaceScore { get; set; }

        public float HeadConfidence { get; set; }
    }
}
