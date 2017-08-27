module Main where

import Anapo.Core
import Anapo.Loop
import Anapo.Render
import Anapo.TestApps

main :: IO ()
main = runClientM $ do
  st <- testAppsInit
  installComponentBootstrap RenderOptions{roAlwaysRerender = False, roDebugOutput = True} st testAppsComponent
