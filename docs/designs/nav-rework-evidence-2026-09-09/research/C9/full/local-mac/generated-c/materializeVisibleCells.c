N_LIB_PRIVATE N_NIMCALL(void, materializeVisibleCells__OOZsrcZshellZbody95nav_u2357)(tyObject_BodyNavSeatcolonObjectType___0c87LTWzqtz7zmat1zT0Kw* seat_p0, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ origin_p1, NI slot_p2) {
	NI radius_1;
	NI diameter_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_254;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_255;
	NI gridW_1;
	NI base_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_256;
	NI entryBase_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_257;
	NI count_1;
NIM_BOOL* nimErr_;
	nimfr_("materializeVisibleCells", "body_nav.nim");
{nimErr_ = nimErrorFlag();
	radius_1 = (*(*seat_p0).dangerGeometry).radius;
	if (nimMulInt(radius_1, ((NI)2), &TM__fw0EGWK0CbR9aJ84zaF6cBg_254)) { raiseOverflow(); goto BeforeRet_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_254), ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_255)) { raiseOverflow(); goto BeforeRet_;
	};
	diameter_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_255);
	gridW_1 = (*seat_p0).danger.gridW;
	if (nimMulInt(slot_p2, (*(*seat_p0).dangerSourceCache).words, &TM__fw0EGWK0CbR9aJ84zaF6cBg_256)) { raiseOverflow(); goto BeforeRet_;
	};
	base_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_256);
	if (nimMulInt(slot_p2, (*(*seat_p0).dangerSourceCache).capacity, &TM__fw0EGWK0CbR9aJ84zaF6cBg_257)) { raiseOverflow(); goto BeforeRet_;
	};
	entryBase_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_257);
	count_1 = ((NI)0);
	{
		NI wordIndex_1;
		NI i_1;
		wordIndex_1 = (NI)0;
		i_1 = ((NI)0);
		{
			while (1) {
				NU64 word_1;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_258;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_272;
				if (!(i_1 < (*(*seat_p0).dangerSourceCache).words)) goto LA3;
				wordIndex_1 = i_1;
				if (nimAddInt(base_1, wordIndex_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_258)) { raiseOverflow(); goto BeforeRet_;
				};
				if ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_258) < 0 || (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_258) >= (*(*seat_p0).dangerSourceCache).bits.len){ raiseIndexError2((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_258),(*(*seat_p0).dangerSourceCache).bits.len-1); goto BeforeRet_;
				}
				word_1 = (*(*seat_p0).dangerSourceCache).bits.p->data[(NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_258)];
				{
					while (1) {
						NI kernelIndex_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_259;
						NI T6_;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_260;
						NI kernelY_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_261;
						NI kernelX_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_262;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_263;
						NI gridIndex_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_264;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_265;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_266;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_267;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_268;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_269;
						NF32 weight_1;
						if (!!((word_1 == 0ULL))) goto LA5;
						if (nimMulInt(wordIndex_1, ((NI)64), &TM__fw0EGWK0CbR9aJ84zaF6cBg_259)) { raiseOverflow(); goto BeforeRet_;
						};
						T6_ = (NI)0;
						T6_ = countTrailingZeroBits__OOZOOZOOZOOZOOZOnimbyZpkgsZzippyZsrcZzippyZinternal_u471(word_1);
						if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
						if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_259), T6_, &TM__fw0EGWK0CbR9aJ84zaF6cBg_260)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelIndex_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_260);
						if (diameter_1 == 0){ raiseDivByZero(); goto BeforeRet_;
						}
						if (nimDivInt(kernelIndex_1, diameter_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_261)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelY_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_261);
						if (nimMulInt(kernelY_1, diameter_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_262)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimSubInt(kernelIndex_1, (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262), &TM__fw0EGWK0CbR9aJ84zaF6cBg_263)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelX_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_263);
						if (nimSubInt(origin_p1.Field1, radius_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_264)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_264), kernelY_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_265)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimMulInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_265), gridW_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_266)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_266), origin_p1.Field0, &TM__fw0EGWK0CbR9aJ84zaF6cBg_267)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimSubInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_267), radius_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_268)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_268), kernelX_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_269)) { raiseOverflow(); goto BeforeRet_;
						};
						gridIndex_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_269);
						if (kernelIndex_1 < 0 || kernelIndex_1 >= (*(*seat_p0).dangerGeometry).kernel.len){ raiseIndexError2(kernelIndex_1,(*(*seat_p0).dangerGeometry).kernel.len-1); goto BeforeRet_;
						}
						weight_1 = (*(*seat_p0).dangerGeometry).kernel.p->data[kernelIndex_1];
						if (gridIndex_1 < 0 || gridIndex_1 >= (*seat_p0).danger.values.len){ raiseIndexError2(gridIndex_1,(*seat_p0).danger.values.len-1); goto BeforeRet_;
						}
						pluseq___OOZOOZOOZOOZOOZOnimbyZpkgsZbumpyZsrcZbumpy_u130((&(*seat_p0).danger.values.p->data[gridIndex_1]), weight_1);
						{
							NI32 colontmpD_;
							NI TM__fw0EGWK0CbR9aJ84zaF6cBg_270;
							tyObject_DangerSourceEntry__Q9arhEVQ9bgP16CdlIu9b9a9bDQ T11_;
							NI TM__fw0EGWK0CbR9aJ84zaF6cBg_271;
							if (!!((weight_1 == 0.0f))) goto LA9_;
							colontmpD_ = (NI32)0;
							if (nimAddInt(entryBase_1, count_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_270)) { raiseOverflow(); goto BeforeRet_;
							};
							if ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_270) < 0 || (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_270) >= (*(*seat_p0).dangerSourceCache).entries.len){ raiseIndexError2((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_270),(*(*seat_p0).dangerSourceCache).entries.len-1); goto BeforeRet_;
							}
							if ((gridIndex_1) < ((NI32)(-2147483647 -1)) || (gridIndex_1) > ((NI32)2147483647)){ raiseRangeErrorI(gridIndex_1, ((NI32)(-2147483647 -1)), ((NI32)2147483647)); goto BeforeRet_;
							}
							colontmpD_ = ((NI32) (gridIndex_1));
							T11_.gridIndex = colontmpD_;
							T11_.weight = weight_1;
							(*(*seat_p0).dangerSourceCache).entries.p->data[(NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_270)] = T11_;
							if (nimAddInt(count_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_271)) { raiseOverflow(); goto BeforeRet_;
							};
							count_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_271);
						}
LA9_: ;
						word_1 = (NU64)(word_1 & (NU64)((NU64)(word_1) - (NU64)(1ULL)));
					} LA5: ;
				}
				if (nimAddInt(i_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_272)) { raiseOverflow(); goto BeforeRet_;
				};
				i_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_272);
			} LA3: ;
		}
	}
	if ((NU)(slot_p2) > (NU)(63)){ raiseIndexError2(slot_p2, 63); goto BeforeRet_;
	}
	if ((count_1) < ((NI32)(-2147483647 -1)) || (count_1) > ((NI32)2147483647)){ raiseRangeErrorI(count_1, ((NI32)(-2147483647 -1)), ((NI32)2147483647)); goto BeforeRet_;
	}
	(*(*seat_p0).dangerSourceCache).slots[(slot_p2)- 0].listLength = ((NI32) (count_1));
	}BeforeRet_: ;
	popFrame();
}