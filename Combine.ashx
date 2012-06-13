<%@ WebHandler Language="C#" Class="Combine" %>

/* CombineAshx -  A single, no configuration ASP.NET file for combining & minifying JavaScript and CSS/LESS files
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
 * Css/Less files:  
 *   combining                  http://my_website/.../Styles/Combine.ashx/css/TableStyles,Typography
 *   combining & minification   http://my_website/.../Styles/Combine.ashx/css,minify/TableStyles,Typography
 * 
 * 
 * 
 *  Version 1.0.3  2012/06/13
 *  Originally written by Dmitry Dzygin, use at your own risk :) */


using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
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
    private static MethodInfo _lessEngine_transformToCssMethodInfo;
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

            _lessEngine_transformToCssMethodInfo = type.GetMethod("TransformToCss", new[] { typeof(string), typeof(string) });
            
            // Reflection: var lessEngine = new dotless.Core.LessEngine();
            object lessEngine = type.GetConstructor(new Type[0]).Invoke(new object[0]);

            // Reflection: (lessEngine.Parser.Importer.FileReader as FileReader).PathResolver = new dotless.Core.Input.AspServerPathResolver();

            object aspServerPathResolver = Type.GetType("dotless.Core.Input.AspServerPathResolver, dotless.Core")
                                           .GetConstructor(new Type[0]).Invoke(new object[0]);
            
            object parser = lessEngine.GetType().GetProperty("Parser").GetValue(lessEngine, new object[0]);
            object importer = parser.GetType().GetProperty("Importer").GetValue(parser, new object[0]);
            object fileReader = importer.GetType().GetProperty("FileReader").GetValue(importer, new object[0]);

            fileReader.GetType().GetProperty("PathResolver").SetValue(fileReader, aspServerPathResolver, new object[0]);
            
            Thread.MemoryBarrier();
            
            _lessEngine = lessEngine;
        }

        // Reflection: return _lessEngine.TransformToCss(fileContentWithoutEncodingSignature, file);
        return _lessEngine_transformToCssMethodInfo.Invoke(_lessEngine, new object[] { fileContentWithoutEncodingSignature, file }) as string;
    }

    
    public void ProcessRequest (HttpContext context) {
        var request = context.Request;
        var response = context.Response;

        string modeStr;
        bool minify;
        
        string[] filesToCombine = GetModeAndFileNamesFromRequest(request, out modeStr, out minify);
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
            SetErrorResponseCode(response);
            response.Write(string.Format("Not allowed mode '{0}'. Allowed values 'js' and 'css'", context.Server.HtmlEncode(modeStr)));
            return;
        }

        string[] extensions = mode == CombiningMode.Scripts ? new[] { ".js" } : new[] { ".css", ".less" };        
                
        
        DateTime lastModifiedDate = DateTime.MinValue;
        List<string> files = new List<string>();
        string physicalFolderPath = request.PhysicalPath.Substring(0, request.PhysicalPath.LastIndexOf("\\", StringComparison.Ordinal) + 1);
        
        
        
        // Gathering information about files
        foreach (string fileName in filesToCombine)
        {
            if (fileName.Contains("..") || fileName.IndexOfAny(Path.GetInvalidPathChars()) > 0)
            {
                SetErrorResponseCode(response);
                context.Response.Write(string.Format("File name '{0}' contains forbidden characters ", context.Server.HtmlEncode(fileName)));
                return;
            }
            
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
                SetErrorResponseCode(response);
                
                response.Write("Cannot find " + ((extensions.Length > 1) ? "one of the following files" : "the following file") + ": ");

                for (int i = 0; i < extensions.Length; i++ )
                {
                    if(i > 0) response.Write(", ");
                    response.Write(context.Server.HtmlEncode(fileName + extensions[i]));
                }
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
                    response.Write(string.Format("Failed to process LESS file '{0}'", context.Server.HtmlEncode(Path.GetFileName(file))));
                   
                    context.Response.Write(context.Server.HtmlEncode(pe.Message));
                    return;
                }
            }

            if (!minify)
            {
                context.Response.Write("\r\n /* File: _fileName_ */\r\n".Replace("_fileName_", Path.GetFileName(file)));
            }

            string outputCode = fileContentWithoutEncodingSignature;

            if(minify)
            {
                outputCode = (mode == CombiningMode.Styles) ? MinifyCSS(outputCode) : MinifyJS(outputCode);
            }

            context.Response.Write(outputCode);
        }
    }
    
    private static string MinifyCSS(string css)
    {
        // remove new lines
        css = Regex.Replace(css, @"(?:\r\n|[\r\n])", "");
        // remove css comments
        css = Regex.Replace(css, @"/\*.+?\*/", "");
        // remove double spaces
        css = Regex.Replace(css, @"\s+", " ");

        StringBuilder sb = new StringBuilder(css);
        sb.Replace("\t", "")
            .Replace("; ", ";")
            .Replace(": ", ":")
            .Replace("{ ", "{")
            .Replace("} ", "}")
            .Replace(", ", ",")
            .Replace(" {", "{")
            .Replace(" }", "}");
        return sb.ToString();
    }
    
    private static string MinifyJS(string js)
    {
        // TODO: to be implemented

        return js;
    }

    private static void SetErrorResponseCode(HttpResponse response)
    {
        response.TrySkipIisCustomErrors = true; // Status code is 500, so IIS may replace it with an error page
        response.StatusCode = 500; 
    }
    
    private static string[] GetModeAndFileNamesFromRequest(HttpRequest request, out string modeStr, out bool minify)
    {
        minify = false;
        
        string pathInfo = request.PathInfo;
        if (string.IsNullOrWhiteSpace(pathInfo))
        {
            modeStr = null;
            return null;
        }

        string[] pathInfoParts = pathInfo.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);

        string[] settings = pathInfoParts[0].ToLowerInvariant().Split(new [] {','}, StringSplitOptions.RemoveEmptyEntries);
        modeStr = settings[0];

        minify = Array.IndexOf(settings, "minify") > -1;
        
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