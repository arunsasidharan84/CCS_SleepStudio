using System;
using System.Globalization;
using NeuroLoopGainLibrary.Edf;
using NeuroLoopGainLibrary.Mathematics;
namespace NeuroLoopGain {
  static class RefMain {
    // args: input.edf signalIndex output.edf F0 B FC smoothrate [undersampler] [LP]
    static int Main(string[] a) {
      var ci = CultureInfo.InvariantCulture;
      var c = NeuroLoopGainController.AppController;
      var conf = new MCconfiguration();
      conf.ShowPiBHistogram = false;
      conf.OverWriteOutputFile = true;
      conf.F0 = double.Parse(a[3], ci); conf.BandWidth = double.Parse(a[4], ci);
      conf.FC = double.Parse(a[5], ci); conf.SmoothRate = double.Parse(a[6], ci);
      conf.IIRUnderSampler = a.Length > 7 ? int.Parse(a[7]) : 0;
      double lp = a.Length > 8 ? double.Parse(a[8], ci) : double.NaN;
      conf.OutputFileName = a[2];
      c.AppConf = conf;
      c.InputEDFFileName = a[0];
      c.InputSignalSelected = int.Parse(a[1]);
      if (conf.IIRUnderSampler == 0) {
        var edf = new EdfFile(a[0], true, false, false, true);
        double fs = edf.SignalInfo[c.InputSignalSelected].NrSamples / edf.FileInfo.SampleRecDuration;
        if (double.IsNaN(lp)) lp = fs / 2;
        double fmin = conf.SafetyFactor * Math.Max(conf.F0, conf.FC);
        double fmax = Math.Min(2 * 0.75 * lp, fs);
        int lo = (int)Math.Truncate(0.99 * fs / fmax) + 1, hi = (int)Math.Truncate(fs / fmin);
        const double want = 56; double fc = -1;
        for (int i = lo; i <= hi; i++) { double d = fs / i;
          if (!MathEx.SameValue(fc, -1) && Math.Abs(want - d) >= Math.Abs(want - fc)) continue;
          conf.IIRUnderSampler = i; fc = d; }
        edf.Active = false;
      }
      Console.WriteLine("undersampler=" + conf.IIRUnderSampler);
      bool ok = c.Analyze();
      Console.WriteLine(ok ? "OK" : "FAILED: " + c.ApplicationError.Message);
      return ok ? 0 : 1;
    }
  }
}
