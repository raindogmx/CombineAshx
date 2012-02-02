<%@ WebHandler Language="C#" Class="Combine" %>

/* CombineAshx -  A single, no configuration ASP.NET file for combining JavaScript or css/less files
 * 
 * 
 * How to use:
 * 
 * 1) Copy to a folder with js/css files
 * 2) Reference it via URL, with specifying compression type add comma separated names of files
 * 3) If you want to use it for combining css resulted from .LESS files, get dotLess.Core.dll from http://www.dotlesscss.org/ and put it into "/Bin" folder of your website 
 * 
 * Examples:
 * 
 * Javascript files:      http://my_website/.../Scripts/Combine.ashx/js/TrackOutbound,TrackRestriction
 * Css/Less files:        http://my_website/.../Styles/Combine.ashx/css/TableStyles,Typography
 * 
 * 
 * Known issues:
 * 
 * - "@import" directives in .less files don't work 
 * 
 * 
 *  Version 1.0.  2012/02/02
 *  Originally written by Dmitry Dzygin, use on your own risk :) */


using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Web;

public class Combine : IHttpHandler {

    private enum CombiningMode
    {
        Styles,
        Scripts
    }
    
    static readonly TimeSpan ExpirationPeriod = new TimeSpan(7, 0, 0, 1); // 7 days and 1 second
    
    static volatile object _lessEngine;
    private static MethodInfo LessEngine_TransformToCssMethodInfo = null;
    static readonly object _lessEngineInitSyncRoot = new object();

    static Combine()
    {
    }


    static string UseDotLessToTransformLessToCss(string fileContentWithoutEncodingSignature, string file)
    {
        // Loading classes from dotless.Core.dll via reflection so the dll isn't required for compilation
        
        if(_lessEngine == null)
        lock(_lessEngineInitSyncRoot)
        if(_lessEngine == null)
        {
            var type = Type.GetType("dotless.Core.LessEngine, dotless.Core"); 
            if(type == null)
            {
                throw new InvalidOperationException("Copy dotless.Core.dll from http://www.dotlesscss.org/ for processing .less files");
            }

            LessEngine_TransformToCssMethodInfo = type.GetMethod("TransformToCss", new[] {typeof (string), typeof (string)});
            
            Thread.MemoryBarrier();
            
            _lessEngine = type.GetConstructor(new Type[0]).Invoke(new object[0]);
        }

        return LessEngine_TransformToCssMethodInfo.Invoke(_lessEngine, new object[] { fileContentWithoutEncodingSignature, Path.GetDirectoryName(file) }) as string;
    }

    
    public void ProcessRequest (HttpContext context) {
        var request = context.Request;
        var response = context.Response;

        string modeStr;
        
        string[] filesToCombine = GetModeAndFileNamesFromRequest(request, out modeStr);
        if(filesToCombine == null)
        {
            response.StatusCode = 500;
            return;
        }


        CombiningMode mode;


        if (modeStr == "js")
        {
            mode = CombiningMode.Scripts;
        }
        else if (modeStr == "css")
        {
            mode = CombiningMode.Styles;
        }
        else
        {
            response.Write("Not allowed mode");
            return;
        }

        string[] extensions = mode == CombiningMode.Scripts ? new[] { ".js" } : new[] { ".css", ".less" };        
                
        
        DateTime lastModifiedDate = DateTime.MinValue;
        List<string> files = new List<string>();
        string physicalFolderPath = request.PhysicalPath.Substring(0, request.PhysicalPath.LastIndexOf("\\", StringComparison.Ordinal) + 1);
        
        
        
        // Gathering information about files
        foreach (string fileName in filesToCombine)
        {
            bool fileFound = false;
            
            string filePath = null;

            foreach(var extension in extensions)
            {
                filePath = physicalFolderPath + fileName + extension;
                
                if(File.Exists(filePath))
                {
                    fileFound = true;
                    break;
                }
            }

            if (!fileFound)
            {
                response.StatusCode = 500;
                return;
            }

            DateTime fileLastUpdated = File.GetLastWriteTime(filePath);
            if(fileLastUpdated > lastModifiedDate)
            {
                lastModifiedDate = fileLastUpdated;
            }
            
            files.Add(filePath);
        }


        context.Response.ContentType = mode == CombiningMode.Scripts ? "application/x-javascript" : "text/css";
        context.Response.ContentEncoding = Encoding.UTF8;

        if(lastModifiedDate != DateTime.MinValue)
        {
            response.Cache.SetLastModified(lastModifiedDate);
        }

        response.Cache.SetExpires(DateTime.Now.Add(ExpirationPeriod));

        foreach(string file in files)
        {
            // TODO: cache file content or write stream that will return file's content without encoding signature
            string fileContentWithoutEncodingSignature = File.ReadAllText(file, Encoding.UTF8);;

            // Parsing LESS syntax if necessary
            if(mode == CombiningMode.Styles && file.EndsWith(".less", StringComparison.InvariantCultureIgnoreCase))
            {
                try
                {
                    fileContentWithoutEncodingSignature = UseDotLessToTransformLessToCss(fileContentWithoutEncodingSignature, file);
                }
                catch (Exception pe)
                {
                    context.Response.StatusCode = 500; // error
                    response.Write(string.Format("Failed to process LESS file '{0}'", Path.GetFileName(file)));
                   
                    context.Response.Write(pe.Message);
                    return;
                }
            }
            
            context.Response.Write("\r\n /* File: _fileName_ */\r\n".Replace("_fileName_", Path.GetFileName(file)));
            context.Response.Write(fileContentWithoutEncodingSignature);
        }
    }

    private static string[] GetModeAndFileNamesFromRequest(HttpRequest request, out string modeStr)
    {
        string pathInfo = request.PathInfo;
        if (string.IsNullOrWhiteSpace(pathInfo))
        {
            modeStr = null;
            return null;
        }

        string[] pathInfoParts = pathInfo.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);

        modeStr = pathInfoParts[0].ToLowerInvariant();
        
        if (pathInfoParts.Length < 2) return null;

        string filesPart = pathInfoParts[1];
        string[] filesToCombine = filesPart.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries);

        return filesToCombine.Length == 0 ? null : filesToCombine;
    }
 
    public bool IsReusable {
        get {
            return false;
        }
    }

}