object EasyEDAForm: TEasyEDAForm
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'EasyEDA Importer'
  ClientHeight = 634
  ClientWidth = 580
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OldCreateOrder = False
  Position = poScreenCenter
  PixelsPerInch = 96
  TextHeight = 15
  object lblTitle: TLabel
    Left = 16
    Top = 12
    Width = 300
    Height = 21
    Caption = 'Import parts from EasyEDA / LCSC'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -16
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object lblSubtitle: TLabel
    Left = 16
    Top = 36
    Width = 540
    Height = 15
    Caption = 'Symbol, footprint and 3D model are downloaded and added to the libraries below.'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
  end
  object gbParts: TGroupBox
    Left = 16
    Top = 60
    Width = 548
    Height = 76
    Caption = ' Parts '
    TabOrder = 0
    object lblParts: TLabel
      Left = 12
      Top = 20
      Width = 520
      Height = 15
      Caption = 'LCSC / JLCPCB part number(s) - separate several with commas, e.g.  C2040, C46749'
    end
    object edtParts: TEdit
      Left = 12
      Top = 40
      Width = 524
      Height = 25
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -14
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
      TabOrder = 0
    end
  end
  object gbLibs: TGroupBox
    Left = 16
    Top = 144
    Width = 548
    Height = 126
    Caption = ' Target libraries '
    TabOrder = 1
    object lblSchLib: TLabel
      Left = 12
      Top = 26
      Width = 90
      Height = 15
      Caption = 'Schematic library'
    end
    object lblPcbLib: TLabel
      Left = 12
      Top = 58
      Width = 90
      Height = 15
      Caption = 'PCB library'
    end
    object lblLibHint: TLabel
      Left = 12
      Top = 92
      Width = 400
      Height = 15
      Caption = 'Empty = EasyEDA.SchLib / .PcbLib.  A new name creates a new library.'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGrayText
      Font.Height = -11
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
    end
    object edtSchLib: TEdit
      Left = 112
      Top = 22
      Width = 340
      Height = 23
      TabOrder = 0
    end
    object btnBrowseSch: TButton
      Left = 460
      Top = 21
      Width = 76
      Height = 25
      Caption = 'Browse...'
      TabOrder = 1
      OnClick = btnBrowseSchClick
    end
    object edtPcbLib: TEdit
      Left = 112
      Top = 54
      Width = 340
      Height = 23
      TabOrder = 2
    end
    object btnBrowsePcb: TButton
      Left = 460
      Top = 53
      Width = 76
      Height = 25
      Caption = 'Browse...'
      TabOrder = 3
      OnClick = btnBrowsePcbClick
    end
    object btnDefaultLibs: TButton
      Left = 416
      Top = 88
      Width = 120
      Height = 25
      Caption = 'Use EasyEDA default'
      TabOrder = 4
      OnClick = btnDefaultLibsClick
    end
  end
  object gbParams: TGroupBox
    Left = 16
    Top = 278
    Width = 548
    Height = 236
    Caption = ' Symbol parameters '
    TabOrder = 2
    object lblParamHint: TLabel
      Left = 12
      Top = 20
      Width = 524
      Height = 15
      Caption = 'One line per parameter:   New name = old name, other old name, ...'
    end
    object lblParamHint2: TLabel
      Left = 12
      Top = 38
      Width = 524
      Height = 15
      Caption = 'Matching ignores upper/lower case, spaces, "_" and "-".  Lines starting with # are notes.'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGrayText
      Font.Height = -11
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
    end
    object memParams: TMemo
      Left = 12
      Top = 58
      Width = 524
      Height = 134
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Consolas'
      Font.Style = []
      ParentFont = False
      ScrollBars = ssBoth
      WordWrap = False
      TabOrder = 0
    end
    object chkOnlyListed: TCheckBox
      Left = 12
      Top = 202
      Width = 300
      Height = 19
      Caption = 'Only keep parameters that are in this list'
      Checked = True
      State = cbChecked
      TabOrder = 1
    end
    object btnDefaultParams: TButton
      Left = 416
      Top = 199
      Width = 120
      Height = 25
      Caption = 'Restore defaults'
      TabOrder = 2
      OnClick = btnDefaultParamsClick
    end
  end
  object gbPlace: TGroupBox
    Left = 16
    Top = 522
    Width = 548
    Height = 60
    Caption = ' Placement '
    TabOrder = 3
    object lblSpacing: TLabel
      Left = 290
      Top = 27
      Width = 44
      Height = 15
      Caption = 'Spacing'
    end
    object lblMil: TLabel
      Left = 396
      Top = 27
      Width = 18
      Height = 15
      Caption = 'mil'
    end
    object lblPerRow: TLabel
      Left = 428
      Top = 27
      Width = 44
      Height = 15
      Caption = 'Per row'
    end
    object chkPlace: TCheckBox
      Left = 12
      Top = 26
      Width = 268
      Height = 19
      Caption = 'Place parts on the open schematic sheet'
      Checked = True
      State = cbChecked
      TabOrder = 0
    end
    object edtSpacing: TEdit
      Left = 340
      Top = 23
      Width = 52
      Height = 23
      TabOrder = 1
      Text = '1500'
    end
    object edtPerRow: TEdit
      Left = 480
      Top = 23
      Width = 56
      Height = 23
      TabOrder = 2
      Text = '6'
    end
  end
  object chkRemember: TCheckBox
    Left = 20
    Top = 598
    Width = 300
    Height = 19
    Caption = 'Remember these settings for next time'
    Checked = True
    State = cbChecked
    TabOrder = 4
  end
  object btnImport: TButton
    Left = 384
    Top = 594
    Width = 88
    Height = 28
    Caption = 'Import'
    Default = True
    ModalResult = 1
    TabOrder = 5
  end
  object btnCancel: TButton
    Left = 476
    Top = 594
    Width = 88
    Height = 28
    Cancel = True
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 6
  end
  object dlgOpen: TOpenDialog
    Options = [ofHideReadOnly, ofFileMustExist, ofEnableSizing]
    Title = 'Choose an existing library'
    Left = 24
    Top = 600
  end
end
