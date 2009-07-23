{- |
The main module for Dyre. The items that it exports are all that
should ever be needed by a program which uses Dyre. The 'Params'
structure is used for all configuration data, and the 'wrapMain'
function is used to obtain the program entry point for the given
configuration data.

The 'defaultParams' record contains suitable default values for
all configuration items except for 'projectName', 'showError', and
'realMain'. By defining those three items using record substitution,
a working program can be integrated with Dyre in only a few lines of
extra code.

For example, a basic program might use Dyre in the following way:

>-- DyreExample.hs --
>module DyreExample ( dyreExample, Config(..), defaultConf ) where
>
>import qualified Config.Dyre as Dyre
>
>data Config = Config { message :: String }
>defaultConf = Config "Hello, world!"
>confError (Config message) error = Config $ "Error:" ++ error ++ "\n" ++ message
>
>realMain (Config message) = do
>    putStrLn "Entered Main Function"
>    putStrLn message
>
>dyreExample = Dyre.wrapMain Dyre.defaultParams
>    { Dyre.projectName  = "dyreExample"
>    , Dyre.showError    = confError
>    , Dyre.realMain     = realMain
>    }
>
>-- Main.hs --
>import DyreExample
>main = dyreExample defaultConf

This will set up a basic project named 'dyreExample', which either prints
a special message, or reports a compilation error. On Posix systems, it
will look for the configuration file according to XDG_CACHE_HOME, and on
Windows it will look under "%USERPROFILE%\Local Settings".

These paths can be overridden by giving a custom value to the 'configDir'
and 'cacheDir' elements, but it is recommended that you not bother.
-}

module Config.Dyre ( wrapMain, Params(..), defaultParams ) where

import Data.Maybe         ( fromMaybe )
import Data.List          ( isPrefixOf, (\\) )
import System.IO          ( openFile, IOMode(..), hClose, hPutStrLn, stderr )
import System.Info        ( os, arch )
import System.FilePath    ( (</>) )
import Control.Exception  ( bracket )
import System.Environment ( getArgs )
import System.Directory   ( getModificationTime, doesFileExist, getCurrentDirectory )

import System.Environment.XDG.BaseDir ( getUserCacheDir, getUserConfigDir )
import System.Environment.Executable  ( getExecutablePath )

import System.IO.Storage   ( putValue, clearAll )

import Config.Dyre.Params  ( Params(..) )
import Config.Dyre.Compile ( customCompile )
import Config.Dyre.Exec    ( customExec )
import Config.Dyre.Launch  ( launchMain )

defaultParams = Params
    { projectName  = undefined
    , configDir    = Nothing
    , cacheDir     = Nothing
    , realMain     = undefined
    , showError    = undefined
    , hidePackages = []
    , ghcOpts      = []
    , statusOut    = hPutStrLn stderr
    }

-- | 'wrapMain' is how Dyre recieves control of the program. It is expected
--   that it will be partially applied with its parameters to yield a "main"
--   entry point, which will then be called by the 'main' function, as well
--   as by any custom configurations.
wrapMain :: Params cfgType -> cfgType -> IO ()
wrapMain params@Params{projectName = pName} cfg = do
    -- Get the important paths
    (thisBinary, tempBinary, configFile, cacheDir) <- getPaths params
    args <- getArgs

    -- Store some data for later
    clearAll "dyre"
    storeFlagValue "--dyre-state-persist=" "persistState"
    storeFlagValue "--dyre-master-binary=" "masterBinary"

    -- Check their modification times
    thisTime <- maybeModTime thisBinary
    tempTime <- maybeModTime tempBinary
    confTime <- maybeModTime configFile

    -- If there's a config file, and the temp binary is older than something
    -- else, or we were specially told to recompile, then we should recompile.
    let confExists = isJust confTime
    errors <- if confExists && or [ tempTime < confTime
                                  , tempTime < thisTime
                                  , "--force-reconf" `elem` args ] ]
                 then customCompile params configFile tempBinary cacheDir
                 else return Nothing

    -- If there's a custom binary and we're not it, run it. Otherwise
    -- just launch the main function.
    customExists <- doesFileExist tempBinary
    if customExists && (thisBinary /= tempBinary)
       then customExec params tempBinary
       else launchMain params errors cfg

-- | Extract the value which follows a command line flag, and store
--   it for future reference.
storeFlagValue :: String -> String -> IO ()
storeFlagValue flagString storeName = do
    args <- getArgs
    let flagArg = filter (isPrefixOf flagString) args
    if null flagArg
       then return ()
       else putValue "dyre" storeName $ (head flagArg) \\ flagString

-- | Calculate the paths to the three important files and the
--   cache directory.
getPaths :: Params c -> IO (FilePath, FilePath, FilePath, FilePath)
getPaths params@Params{projectName = pName} = do
    args <- getArgs
    thisBinary <- getExecutablePath
    let debug = "--dyre-debug" `elem` args
    cwd <- getCurrentDirectory
    cacheDir  <- case (debug, cacheDir params) of
                      (True,  _      ) -> return $ cwd </> "cache"
                      (False, Nothing) -> getUserCacheDir pName
                      (False, Just cd) -> cd
    configDir <- case (debug, configDir params) of
                      (True,  _      ) -> return $ cwd
                      (False, Nothing) -> getUserConfigDir pName
                      (False, Just cd) -> cd
    let tempBinary = cacheDir </> pName ++ "-" ++ os ++ "-" ++ arch
    let configFile = configDir </> pName ++ ".hs"
    return $ (thisBinary, tempBinary, configFile, cacheDir)

-- | Check if a file exists. If it exists, return Just the modification
--   time. If it doesn't exist, return Nothing.
maybeModTime path = do
    fileExists <- doesFileExist path
    if fileExists
       then fmap Just $ getModificationTime path
       else return Nothing
