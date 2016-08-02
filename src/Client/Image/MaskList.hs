{-# Language OverloadedStrings #-}
{-|
Module      : Client.Image.MaskList
Description : Line renderers for channel mask list view
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

This module renders the lines used in the channel mask list. A mask list
can show channel bans, quiets, invites, and exceptions.
-}
module Client.Image.MaskList
  ( maskListImages
  ) where

import           Client.ChannelState
import           Client.ConnectionState
import           Client.State
import           Control.Lens
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import           Data.List
import           Data.Ord
import           Data.Text (Text)
import           Data.Time
import           Graphics.Vty.Image
import           Irc.Identifier

-- | Render the lines used in a channel mask list
maskListImages ::
  Char        {- ^ Mask mode -} ->
  NetworkName {- ^ Focused network -} ->
  Identifier  {- ^ Focused channel -} ->
  ClientState -> [Image]
maskListImages mode network channel st =
  case mbEntries of
    Nothing      -> [text' (withForeColor defAttr red) "Mask list not loaded"]
    Just entries -> maskListImages' entries st

  where
    mbEntries = preview
                ( clientConnection network
                . csChannels . ix channel
                . chanLists . ix mode
                ) st

maskListImages' :: HashMap Text (Text, UTCTime) -> ClientState -> [Image]
maskListImages' entries st = countImage : images
  where
    countImage = text' (withForeColor defAttr green) "Masks (visible/total): " <|>
                 string defAttr (show (length entryList)) <|>
                 char (withForeColor defAttr green) '/' <|>
                 string defAttr (show (HashMap.size entries))

    matcher = clientMatcher st

    matcher' (x,(y,_)) = matcher x || matcher y

    entryList = sortBy (flip (comparing (snd . snd)))
              $ filter matcher'
              $ HashMap.toList entries

    renderWhen = formatTime defaultTimeLocale " %F %T"

    (masks, whoWhens) = unzip entryList
    maskImages       = text' defAttr <$> masks
    maskColumnWidth  = maximum (imageWidth <$> maskImages) + 1
    paddedMaskImages = resizeWidth maskColumnWidth <$> maskImages
    width            = max 1 (view clientWidth st)

    images = [ cropLine $ mask <|>
                          text' defAttr who <|>
                          string defAttr (renderWhen when)
             | (mask, (who, when)) <- zip paddedMaskImages whoWhens ]

    cropLine img
      | imageWidth img > width = cropRight width img
      | otherwise              = img
