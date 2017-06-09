{-# LANGUAGE OverloadedStrings #-}

import           Data.Maybe  (fromMaybe)
import           Data.Monoid (mappend)
import           Hakyll      hiding (defaultContext)
import qualified Hakyll      as Hakyll

main :: IO ()
main = hakyll $ do
  match "assets/**" $ do
    route idRoute
    compile copyFileCompiler

  match "raw/**" $ do
    route idRoute
    compile compressCssCompiler

  match (fromList ["about.rst", "contact.markdown"]) $ do
    route $ setExtension "html"
    compile $ pandocCompiler
      >>= loadAndApplyTemplate "templates/default.html" defaultContext
      >>= relativizeUrls

  match "posts/*" $ do
    route $ setExtension "html"
    compile $ pandocCompiler
      >>= loadAndApplyTemplate "templates/post.html" postCtx
      >>= saveSnapshot "content"
      >>= loadAndApplyTemplate "templates/default.html" postCtx
      >>= relativizeUrls

  create ["archive.html"] $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll "posts/*"
      let archiveCtx =
            listField "posts" postCtx (return posts) `mappend`
            constField "title" "Archives" `mappend`
            defaultContext

      makeItem ""
        >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
        >>= loadAndApplyTemplate "templates/default.html" archiveCtx
        >>= relativizeUrls

  create ["feed.atom"] $ do
    route idRoute
    compile $ do
      let feedCtx = postCtx `mappend` summaryContext
      posts <- fmap (take 10) . recentFirst =<< loadAllSnapshots "posts/*" "content"
      renderAtom feedConfig feedCtx posts

  match "index.html" $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll "posts/*"
      let indexCtx =
            listField "posts" postCtx (return posts) `mappend`
            constField "title" "Home" `mappend`
            defaultContext

      getResourceBody
        >>= applyAsTemplate indexCtx
        >>= loadAndApplyTemplate "templates/default.html" indexCtx
        >>= relativizeUrls

  match "templates/*" $ compile templateBodyCompiler

postCtx :: Context String
postCtx =
  dateField "date" "%B %e, %Y" `mappend`
  dateField "day" "%e" `mappend`
  dateField "month" "%B" `mappend`
  Hakyll.defaultContext

defaultContext :: Context String
defaultContext =
  boolField "showPageTitle" (const True) `mappend`
  Hakyll.defaultContext

summaryContext :: Context String
summaryContext = field "description" $ \item -> do
  metadata <- getMetadata (itemIdentifier item)
  return $ fromMaybe "No summary available" $ lookupString "summary" metadata

feedConfig :: FeedConfiguration
feedConfig =
  FeedConfiguration
  { feedTitle = "Boring Haskell"
  , feedDescription = "Just me doing boring stuff with Haskell"
  , feedAuthorName = "Philipp Maier"
  , feedAuthorEmail = "@AkiiZedd"
  , feedRoot = "http://blog.akii.de"
  }
